import Foundation
import ZCore
import ZAgent

/// The result of a team run.
public struct TeamOutcome: Hashable, Codable, Sendable {
    /// True when every task on the board is done (and the team was not stopped).
    public var success: Bool
    /// The lead's final report (or a generated summary when the lead could not write one).
    public var report: String
    /// The reviewer's verdict, when there was a review.
    public var review: String?
    /// The final board: per-task status, assignee, result, attempts.
    public var tasks: [TeamTask]
    /// Tokens over every member's runs.
    public var usage: Usage
    public var usageByMember: [String: Usage]
    public var stopped: Bool
    public var duration: TimeInterval

    public init(success: Bool, report: String, review: String? = nil, tasks: [TeamTask], usage: Usage,
                usageByMember: [String: Usage] = [:], stopped: Bool = false, duration: TimeInterval = 0) {
        self.success = success; self.report = report; self.review = review; self.tasks = tasks; self.usage = usage
        self.usageByMember = usageByMember; self.stopped = stopped; self.duration = duration
    }

    /// Task id → result text.
    public var results: [String: String] {
        var out: [String: String] = [:]
        for t in tasks { if let r = t.result { out[t.id] = r } }
        return out
    }
}

/// Runs a team: one `AgentRunner` per member on a shared machine and event bus.
///
/// Phases: the lead plans the goal into board tasks (`board_plan`; when it does not call it, a list in its reply or
/// the whole goal becomes the plan) → workers claim and do tasks concurrently, at most `maxParallelWorkers` at a
/// time, until none is left (a failed task is tried once more) → the reviewer checks the results and may reopen
/// tasks once, which the workers then redo → the lead writes the final report (`TeamOutcome`).
///
/// Each member's surface is a `LeasedSurface` over the shared one, so input is serialised by `lease`.
/// Members' events go to `bus` under their member ids; team changes go to `teamEvents()` and, as notes from the
/// "Team" pseudo-agent, to `bus`.
public actor TeamRunner {
    /// Makes the model client for a member (e.g. `ProviderClientFactory.makeClient` for its `ModelRef`).
    public typealias ClientFactory = @Sendable (TeamMember) async throws -> any LLMClient

    public nonisolated let id: String
    public nonisolated let spec: TeamSpec
    public nonisolated let roster: TeamRoster
    public nonisolated let bus: EventBus
    public nonisolated let hub: TeamEventHub
    public nonisolated let reporter: TeamReporter
    public nonisolated let board: TaskBoard
    public nonisolated let messages: MessageBus
    /// Nil when the team has no machine.
    public nonisolated let lease: SurfaceLease?
    public nonisolated let surface: (any ComputerSurface)?
    public nonisolated let toolbox: TeamToolbox

    private let clientFactory: ClientFactory
    private let memory: (any MemoryStore)?
    private let episodeSink: (any EpisodeSink)?
    private let imageResizer: any ImageResizer
    private let surfaceOptions: LeasedSurface.Options

    public private(set) var phase: TeamPhase = .idle
    public private(set) var outcome: TeamOutcome?
    private var runners: [String: AgentRunner] = [:]
    private var leasedSurfaces: [String: LeasedSurface] = [:]
    private var mainTask: Task<TeamOutcome, Never>?
    private var started = false
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false
    private var reviewText: String?

    /// - Parameters:
    ///   - surface: the shared machine (each member gets a `LeasedSurface` over it).
    ///   - memory: the library shared by all members (optional).
    ///   - bus: where every member's events go (share it with the activity panel).
    ///   - surfaceOptions: lease behaviour per member surface; default: `spec.shellOutsideLease`, hold until the
    ///     agent's next screenshot.
    ///   - clientFactory: makes each member's model client; called once per member by `start()`.
    public init(id: String = UUID().uuidString,
                spec: TeamSpec,
                surface: (any ComputerSurface)? = nil,
                memory: (any MemoryStore)? = nil,
                bus: EventBus = EventBus(),
                episodeSink: (any EpisodeSink)? = nil,
                imageResizer: any ImageResizer = PassThroughImageResizer(),
                surfaceOptions: LeasedSurface.Options? = nil,
                clientFactory: @escaping ClientFactory) {
        let roster = spec.roster
        let hub = TeamEventHub()
        let reporter = TeamReporter(hub: hub, bus: bus, agentID: "team:\(id)", agentName: "Team", roster: roster)
        let board = TaskBoard(maxAttempts: spec.maxAttemptsPerTask, maxReopens: spec.allowReopen ? 1 : 0, reporter: reporter)
        let messages = MessageBus(roster: roster, reporter: reporter)
        var duties: [String: TeamDuties] = [:]
        for m in spec.members { duties[m.id] = spec.duties(of: m.id) }

        self.id = id
        self.spec = spec
        self.roster = roster
        self.bus = bus
        self.hub = hub
        self.reporter = reporter
        self.board = board
        self.messages = messages
        self.surface = surface
        self.lease = surface == nil ? nil : SurfaceLease(maxHoldTime: spec.leaseMaxHold, reporter: reporter)
        self.toolbox = TeamToolbox(board: board, messages: messages, roster: roster, duties: duties)
        self.clientFactory = clientFactory
        self.memory = memory
        self.episodeSink = episodeSink
        self.imageResizer = imageResizer
        self.surfaceOptions = surfaceOptions ?? LeasedSurface.Options(shellOutsideLease: spec.shellOutsideLease)
    }

    // MARK: Events

    /// Every member's agent events (from `bus`) and the team's events, merged. Ends when the consumer is cancelled.
    public nonisolated func events(replayHistory: Bool = false) -> AsyncStream<TeamFeedEvent> {
        let agents = bus.subscribe(replayHistory: replayHistory)
        let team = hub.subscribe(replayHistory: replayHistory)
        let memberIDs = Set(spec.members.map(\.id))
        return AsyncStream { continuation in
            let agentPump = Task {
                for await envelope in agents where memberIDs.contains(envelope.agentID) {
                    continuation.yield(.agent(envelope))
                }
            }
            let teamPump = Task {
                for await event in team { continuation.yield(.team(event)) }
            }
            continuation.onTermination = { _ in
                agentPump.cancel()
                teamPump.cancel()
            }
        }
    }

    /// Only the team's events (board, messages, lease, phases).
    public nonisolated func teamEvents(replayHistory: Bool = false) -> AsyncStream<TeamEvent> {
        hub.subscribe(replayHistory: replayHistory)
    }

    // MARK: Lifecycle

    /// Makes every member's model client and agent, then starts the run in the background.
    /// Throws for an invalid spec, a client that cannot be made, or a second start (a runner runs once).
    public func start() async throws {
        guard !started else {
            throw ZError.invalidArgument("This team was already started; make a new TeamRunner for another run.")
        }
        try spec.validate()
        started = true
        do {
            for member in spec.members {
                let client = try await clientFactory(member)
                runners[member.id] = makeRunner(member, client: client)
            }
        } catch {
            runners.removeAll()
            leasedSurfaces.removeAll()
            started = false
            reporter.report(.note("Could not start the team: \(Self.describe(error))"))
            throw error
        }
        mainTask = Task { await self.orchestrate() }
    }

    /// Starts and waits for the outcome (a failed outcome when the team cannot start).
    @discardableResult
    public func run() async -> TeamOutcome {
        if !started {
            do {
                try await start()
            } catch {
                return TeamOutcome(success: false, report: "The team could not start: \(Self.describe(error))",
                                   tasks: [], usage: Usage())
            }
        }
        if let outcome = await waitForCompletion() { return outcome }
        return TeamOutcome(success: false, report: "The team did not run.", tasks: [], usage: Usage())
    }

    /// Waits for the run to end (or returns the outcome when it already ended; nil before `start()`).
    public func waitForCompletion() async -> TeamOutcome? {
        guard let task = mainTask else { return outcome }
        return await task.value
    }

    /// Pauses every member at its next checkpoint; no new task starts until `resume()`.
    public func pause() async {
        guard started, !paused, !stopRequested, !phase.isFinal else { return }
        paused = true
        reporter.report(.note("The team is paused."))
        for runner in runners.values { await runner.pause() }
    }

    public func resume() async {
        guard paused else { return }
        paused = false
        for runner in runners.values { await runner.resume() }
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume() }
        reporter.report(.note("The team resumed."))
    }

    /// Stops everyone: running agents stop, waiting ones give up, no new task starts. The outcome is `stopped`.
    public func stop() async {
        guard started, !stopRequested, !phase.isFinal else { return }
        stopRequested = true
        paused = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume() }
        await board.close()
        await lease?.cancelAll()
        for runner in runners.values { await runner.stop() }
        mainTask?.cancel()
    }

    // MARK: Members

    public var isStarted: Bool { started }
    public var isPaused: Bool { paused }
    public var isStopped: Bool { stopRequested }

    /// The agent of a member (nil before `start()`).
    public func runner(for memberID: String) -> AgentRunner? { runners[memberID] }

    /// The leased view of the machine a member works on (nil without a machine or before `start()`).
    public func leasedSurface(for memberID: String) -> LeasedSurface? { leasedSurfaces[memberID] }

    public func status(of memberID: String) async -> AgentStatus? {
        guard let runner = runners[memberID] else { return nil }
        return await runner.status
    }

    /// Member id → agent status.
    public func memberStatuses() async -> [String: AgentStatus] {
        var out: [String: AgentStatus] = [:]
        for (id, runner) in runners { out[id] = await runner.status }
        return out
    }

    /// Token usage so far over all members.
    public func usage() async -> Usage {
        var total = Usage()
        for runner in runners.values { total = total + (await runner.totalUsage) }
        return total
    }

    /// Approval requests waiting across the team (each carries its member's `agentID`).
    public func pendingApprovals() async -> [ApprovalRequest] {
        var out: [ApprovalRequest] = []
        for m in spec.members {
            guard let runner = runners[m.id] else { continue }
            out += await runner.pendingApprovals
        }
        return out
    }

    /// Resolves an approval on the member that asked for it (`memberID`, or whichever member has a pending request
    /// with that id). Returns false when nothing was waiting.
    @discardableResult
    public func approve(id: String, decision: ApprovalDecision, memberID: String? = nil) async -> Bool {
        if let memberID {
            guard let runner = runners[memberID] else { return false }
            return await runner.approve(id: id, decision: decision)
        }
        for m in spec.members {
            guard let runner = runners[m.id] else { continue }
            let pending = await runner.pendingApprovals
            if pending.contains(where: { $0.id == id }) {
                return await runner.approve(id: id, decision: decision)
            }
        }
        return false
    }

    /// A message from the user to one member (id, name or role), or — with `to` nil — to every member that is
    /// working right now (the lead when nobody is). It answers a pending `ask_user` question or is injected before
    /// the member's next model call. Returns false when nobody received it.
    @discardableResult
    public func send(userMessage: String, to member: String? = nil) async -> Bool {
        let text = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var targets: [TeamMember] = []
        if let member {
            guard let m = roster.resolve(member) else { return false }
            targets = [m]
        } else {
            for m in spec.members {
                if let runner = runners[m.id], await runner.isRunning { targets.append(m) }
            }
            if targets.isEmpty, let lead = spec.lead { targets = [lead] }
        }
        var delivered = false
        for m in targets {
            guard let runner = runners[m.id] else { continue }
            await runner.send(userMessage: text)
            await messages.record(from: TeamRoster.userID, to: m.id, text: text)
            delivered = true
        }
        return delivered
    }

    // MARK: Orchestration

    private var isStopping: Bool { stopRequested || Task.isCancelled }

    private func orchestrate() async -> TeamOutcome {
        let startedAt = Date()
        guard let lead = spec.lead else {
            return await finish(startedAt: startedAt, report: "The team has no members.")
        }

        // 1. Plan.
        if !isStopping {
            setPhase(.planning)
            let plan = await runMember(lead, prompt: TeamPrompts.plan(goal: spec.goal, workers: spec.workers, roster: roster))
            if !isStopping, await board.isEmpty {
                let drafts = TaskDraft.parseList(plan.summary)
                if drafts.count >= 2 {
                    reporter.report(.note("The lead did not call board_plan; its list became the plan."))
                    await board.plan(from: drafts)
                } else {
                    reporter.report(.note("The lead did not plan tasks; the whole goal is one task."))
                    await board.add(title: Self.title(for: spec.goal), detail: spec.goal)
                }
            }
        }

        // 2. Work.
        if !isStopping {
            setPhase(.working)
            await workPhase()
        }

        // 3. Review (reopened tasks get one more round of work).
        if !isStopping, let reviewer = spec.reviewer {
            setPhase(.reviewing)
            let boardText = await board.summary()
            let verdict = await runMember(reviewer, prompt: TeamPrompts.review(goal: spec.goal, board: boardText,
                                                                                allowReopen: spec.allowReopen))
            if !isStopping {
                let text = verdict.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                reviewText = text.isEmpty ? nil : text
                if await board.hasOpenWork {
                    setPhase(.working)
                    await workPhase()
                }
            }
        }

        // 4. Report.
        var report = ""
        if !isStopping {
            setPhase(.reporting)
            let boardText = await board.summary()
            let result = await runMember(lead, prompt: TeamPrompts.report(goal: spec.goal, board: boardText, review: reviewText))
            let text = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            // A report that says the goal was not met is still a report; fall back only when the run itself failed.
            let wroteReport = await runners[lead.id]?.status == .finished
            if wroteReport, !text.isEmpty {
                report = text
            } else if !isStopping {
                report = TeamPrompts.fallbackReport(goal: spec.goal, tasks: await board.tasks)
                if !text.isEmpty { report += "\n\n(The lead could not write the report: \(text))" }
            }
        }
        return await finish(startedAt: startedAt, report: report)
    }

    private func workPhase() async {
        let workers = spec.workers
        guard !workers.isEmpty else { return }
        for pass in 0..<2 {
            if isStopping { return }
            if pass > 0 {
                // Tasks nobody could claim (given to a member that is not working): open them to every worker, once.
                var opened = 0
                let tasks = await board.tasks
                for t in tasks where t.status == .todo && t.assignee != nil {
                    if (try? await board.assign(t.id, to: nil)) != nil { opened += 1 }
                }
                if opened == 0 { return }
            }
            let slots = AsyncSemaphore(max(1, min(spec.maxParallelWorkers, workers.count)))
            await withTaskGroup(of: Void.self) { group in
                for worker in workers {
                    group.addTask { await self.workerLoop(worker, slots: slots) }
                }
            }
        }
    }

    /// One worker: take a slot, claim a ready task, do it; wait while work may still come; stop when none can.
    private func workerLoop(_ worker: TeamMember, slots: AsyncSemaphore) async {
        while !isStopping {
            await waitIfPaused()
            if isStopping { return }
            guard await slots.acquire() else { return }
            if isStopping {
                await slots.release()
                return
            }
            if let task = await board.claimNext(for: worker.id) {
                await work(on: task, by: worker)
                await slots.release()
                continue
            }
            await slots.release()
            guard await board.waitForWork(for: worker.id) else { return }
        }
    }

    private func work(on task: TeamTask, by worker: TeamMember) async {
        let taskText = await toolbox.describeTaskForWorker(task)
        let unread = await messages.unreadCount(for: worker.id)
        let outcome = await runMember(worker, prompt: TeamPrompts.work(goal: spec.goal, taskText: taskText, unreadMessages: unread))
        let others = await board.tasks.filter { $0.id != task.id && $0.assignee == worker.id && $0.status == .doing }
        if stopRequested {
            await board.requeue(task.id, note: "Interrupted: the team was stopped.")
            for t in others { await board.requeue(t.id, note: "Interrupted: the team was stopped.") }
            return
        }
        await board.finishAttempt(task.id, success: outcome.success, result: outcome.summary)
        // Tasks the worker claimed itself during the run (board_claim) end with the run.
        for t in others { await board.finishAttempt(t.id, success: outcome.success, result: outcome.summary) }
    }

    /// Runs one task on a member's agent and waits for the outcome, honouring pause and stop.
    private func runMember(_ member: TeamMember, prompt: String) async -> AgentOutcome {
        guard let runner = runners[member.id] else {
            return AgentOutcome(success: false, summary: "\(member.name) has no agent.", steps: 0, usage: Usage())
        }
        await waitIfPaused()
        if isStopping { return Self.stoppedOutcome }
        await runner.start(task: prompt)
        // stop() / pause() may have run while the run was starting.
        if stopRequested {
            await runner.stop()
        } else if paused {
            await runner.pause()
        }
        return await runner.waitForCompletion()
            ?? AgentOutcome(success: false, summary: "The run ended without an outcome.", steps: 0, usage: Usage())
    }

    private func waitIfPaused() async {
        while paused && !stopRequested {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                pauseWaiters.append(c)
            }
        }
    }

    private func finish(startedAt: Date, report: String) async -> TeamOutcome {
        let tasks = await board.tasks
        var byMember: [String: Usage] = [:]
        var total = Usage()
        for (id, runner) in runners {
            let u = await runner.totalUsage
            byMember[id] = u
            total = total + u
        }
        let stopped = stopRequested
        let success = !stopped && !tasks.isEmpty && tasks.allSatisfy { $0.status == .done }
        var text = report
        if stopped, text.isEmpty { text = "Stopped by the user." }
        let result = TeamOutcome(success: success, report: text, review: reviewText, tasks: tasks, usage: total,
                                 usageByMember: byMember, stopped: stopped, duration: Date().timeIntervalSince(startedAt))
        outcome = result
        setPhase(stopped ? .stopped : (success ? .finished : .failed))
        reporter.report(.finished(result))
        return result
    }

    private func setPhase(_ new: TeamPhase) {
        guard phase != new else { return }
        phase = new
        reporter.report(.phase(new))
    }

    private func makeRunner(_ member: TeamMember, client: any LLMClient) -> AgentRunner {
        var memberSurface: (any ComputerSurface)?
        if let surface, let lease {
            let leased = LeasedSurface(base: surface, lease: lease, holder: member.id, options: surfaceOptions)
            leasedSurfaces[member.id] = leased
            memberSurface = leased
        }
        let duties = spec.duties(of: member.id)
        let instructions = TeamPrompts.instructions(for: member, duties: duties, roster: roster,
                                                    sharedScreen: surface != nil && spec.members.count > 1,
                                                    allowReopen: spec.allowReopen)
        return AgentRunner(id: member.id, name: member.name, client: client, surface: memberSurface, memory: memory,
                           policy: member.policy ?? spec.defaultPolicy, instructions: instructions,
                           extraTools: toolbox.tools(for: duties, allowReopen: spec.allowReopen),
                           bus: bus, episodeSink: episodeSink, imageResizer: imageResizer)
    }

    static let stoppedOutcome = AgentOutcome(success: false, summary: "Stopped by the user.", steps: 0, usage: Usage())

    /// A short task title from a goal (its first line, clipped).
    static func title(for goal: String) -> String {
        let first = goal.split(whereSeparator: \.isNewline).first.map(String.init) ?? goal
        let t = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > 100 ? String(t.prefix(99)) + "…" : t
    }

    static func describe(_ error: Error) -> String {
        if let z = error as? ZError { return z.description }
        return String(describing: error)
    }
}

// MARK: - Semaphore

/// A counting semaphore for tasks; waiting is FIFO and cancellable (`acquire` returns false when cancelled).
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(_ count: Int) { available = max(0, count) }

    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                waiters.append((id: id, continuation: c))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        }
    }

    private func cancel(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: i)
        w.continuation.resume(returning: false)
    }
}
