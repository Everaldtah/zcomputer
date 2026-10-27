import Foundation
import ZCore

/// One agent working on one machine with one model.
///
/// The loop: build the system prompt (machine + memory context + tool guidance) → stream a completion
/// (text / reasoning deltas become events) → run the tool calls (approval gate, call / result / screenshot events)
/// → repeat until `task_complete`, a plain-text answer, the step limit, `stop()` or an error. At the end the run is
/// handed to the `EpisodeSink`.
///
/// All events go to `bus` (an `EventBus`) as `AgentEventEnvelope`s tagged with this agent's id; `events()` gives a
/// stream filtered to this agent. The transcript is kept between runs, so `run(task:)` again continues the
/// conversation (call `reset()` to start fresh).
public actor AgentRunner {
    // MARK: Identity and collaborators

    public nonisolated let id: String
    public nonisolated let name: String
    public nonisolated let client: any LLMClient
    public nonisolated let surface: (any ComputerSurface)?
    public nonisolated let memory: (any MemoryStore)?
    public nonisolated let bus: EventBus
    public nonisolated let emitter: AgentEmitter
    public nonisolated let approvalGate: ApprovalGate
    public nonisolated let userInput: UserInputChannel

    // MARK: State

    public private(set) var policy: AgentPolicy
    public private(set) var status: AgentStatus = .idle
    /// The conversation so far (without the system prompt). Old screenshots are already replaced by placeholders.
    public private(set) var transcript: [ChatMessage] = []
    public private(set) var lastOutcome: AgentOutcome?
    public private(set) var currentTask: String?
    /// Usage over every run of this runner.
    public private(set) var totalUsage = Usage()

    private let instructions: String?
    private let customTools: ToolRegistry?
    private let extraTools: [any Tool]
    private let episodeSink: (any EpisodeSink)?
    private let memoryContext: (any MemoryContextProvider)?
    private let imageResizer: any ImageResizer
    private let nativeBridge: (any NativeComputerBridge)?
    private let scratchDirectory: URL

    private var queuedMessages: [String] = []
    private var paused = false
    private var stopRequested = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var statusBeforePause: AgentStatus = .thinking
    private var loopTask: Task<AgentOutcome, Never>?
    private var runCount = 0
    private var runSteps = 0
    private var runUsage = Usage()

    /// - Parameters:
    ///   - tools: replaces the standard tool set (computer/shell/files when `surface` is set, memory tools when
    ///     `memory` is set, task tools always). `extraTools` are added on top either way (e.g. team tools).
    ///   - memoryContext: builds the memory block of the system prompt when `memory` is set (nil disables it).
    ///   - imageResizer: downscales screenshots (the app passes a CoreGraphics resizer; the default keeps them as-is).
    ///   - nativeBridge: native computer-use translation. Nil = the default bridge for the model's
    ///     `nativeComputerUse` kind (`NativeComputerBridges.bridge(for:)`); used only when `policy.useNativeComputerUse`
    ///     is on and tools are called natively. Pass e.g. `AnthropicComputerBridge(version: .legacy20251124)` for
    ///     models on the older tool version.
    public init(id: String = UUID().uuidString,
                name: String = "Agent",
                client: any LLMClient,
                surface: (any ComputerSurface)? = nil,
                memory: (any MemoryStore)? = nil,
                policy: AgentPolicy = AgentPolicy(),
                instructions: String? = nil,
                tools: ToolRegistry? = nil,
                extraTools: [any Tool] = [],
                bus: EventBus = EventBus(),
                episodeSink: (any EpisodeSink)? = nil,
                memoryContext: (any MemoryContextProvider)? = DefaultMemoryContextProvider(),
                imageResizer: any ImageResizer = PassThroughImageResizer(),
                nativeBridge: (any NativeComputerBridge)? = nil,
                scratchDirectory: URL? = nil) {
        self.id = id
        self.name = name
        self.client = client
        self.surface = surface
        self.memory = memory
        self.bus = bus
        let emitter = AgentEmitter(agentID: id, agentName: name, sink: bus)
        self.emitter = emitter
        self.approvalGate = ApprovalGate(mode: policy.approvalMode, emitter: emitter)
        self.userInput = UserInputChannel()
        self.policy = policy
        self.instructions = instructions
        self.customTools = tools
        self.extraTools = extraTools
        self.episodeSink = episodeSink
        self.memoryContext = memoryContext
        self.imageResizer = imageResizer
        self.nativeBridge = nativeBridge
        self.scratchDirectory = scratchDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("zagent-\(id)", isDirectory: true)
    }

    // MARK: Public API

    /// Live events of this agent (filtered from `bus`). The stream ends when the consumer is cancelled.
    public nonisolated func events(replayHistory: Bool = false) -> AsyncStream<AgentEventEnvelope> {
        let upstream = bus.subscribe(replayHistory: replayHistory)
        let agentID = id
        return AsyncStream { continuation in
            let pump = Task {
                for await envelope in upstream where envelope.agentID == agentID {
                    continuation.yield(envelope)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    public var isRunning: Bool { loopTask != nil }
    public var isPaused: Bool { paused }
    public var queuedMessageCount: Int { queuedMessages.count }

    /// Approval requests waiting for the user.
    public var pendingApprovals: [ApprovalRequest] {
        get async { await approvalGate.pendingRequests }
    }

    /// The `ask_user` question waiting for an answer, if any (answer it with `send(userMessage:)`).
    public var pendingQuestion: String? {
        get async { await userInput.pendingQuestion }
    }

    /// Runs a task to the end and returns the outcome. If a run is already in progress, `task` is delivered as a
    /// user message (see `send(userMessage:)`) and the current run's outcome is returned.
    /// Cancelling the calling task stops the run.
    @discardableResult
    public func run(task: String) async -> AgentOutcome {
        await start(task: task)
        guard let t = loopTask else {
            return lastOutcome ?? AgentOutcome(success: false, summary: "The agent did not start.", steps: 0, usage: Usage())
        }
        return await withTaskCancellationHandler {
            await t.value
        } onCancel: {
            Task { await self.stop() }
        }
    }

    /// Starts a run in the background and returns immediately (true), or — when a run is in progress — delivers
    /// `task` as a user message (false). Use `events()` / `status` / `waitForCompletion()` to follow it.
    @discardableResult
    public func start(task: String) async -> Bool {
        guard loopTask == nil else {
            await send(userMessage: task)
            return false
        }
        stopRequested = false
        paused = false
        runCount += 1
        loopTask = Task { await self.runLoop(task: task) }
        return true
    }

    /// Waits for the current run (or returns the last outcome when idle).
    public func waitForCompletion() async -> AgentOutcome? {
        guard let t = loopTask else { return lastOutcome }
        return await t.value
    }

    /// A message from the user while the agent works. Answers a pending `ask_user` question if there is one;
    /// otherwise it is queued and injected before the next model call (or at the start of the next run).
    public func send(userMessage: String) async {
        let text = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if await userInput.answer(text) {
            emitter.emit(.message(.user(text)))
            return
        }
        queuedMessages.append(text)
    }

    /// Pauses at the next checkpoint (before a model call or a tool call).
    public func pause() {
        guard loopTask != nil, !paused else { return }
        paused = true
        statusBeforePause = status
        status = .paused
        emitter.emit(.status(.paused))
    }

    public func resume() {
        guard paused else { return }
        paused = false
        let restored = statusBeforePause == .paused ? .thinking : statusBeforePause
        if status != restored {
            status = restored
            emitter.emit(.status(restored))
        }
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// Stops the run: cancels the model stream / tool in flight, denies pending approvals, cancels `ask_user`.
    public func stop() async {
        guard let task = loopTask else { return }
        stopRequested = true
        task.cancel()
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume() }
        await approvalGate.cancelAll()
        await userInput.cancel()
    }

    /// Resolves an approval request (the id is the tool call id). Returns false when nothing was waiting.
    @discardableResult
    public func approve(id: String, decision: ApprovalDecision) async -> Bool {
        await approvalGate.decide(id: id, decision: decision)
    }

    /// Changes the policy; takes effect at the next step (approval mode immediately).
    public func setPolicy(_ policy: AgentPolicy) async {
        self.policy = policy
        await approvalGate.setMode(policy.approvalMode)
    }

    /// Forgets the conversation (only while idle).
    public func reset() {
        guard loopTask == nil else { return }
        transcript.removeAll()
        queuedMessages.removeAll()
        lastOutcome = nil
        if status != .idle {
            status = .idle
            emitter.emit(.status(.idle))
        }
    }

    // MARK: The loop

    struct RunSetup: Sendable {
        var registry: ToolRegistry
        /// Tools passed to the model (empty in text mode: they are described in the prompt instead).
        var toolSpecs: [ToolSpec]
        var systemPrompt: String
        var textMode: Bool
        var vision: Bool
        var hasDesktop: Bool
        var computer: ComputerTool?
        var parser: TextToolCallParser
        var context: ContextManager
    }

    struct StepResult: Sendable {
        var text = ""
        var reasoning = ""
        var toolCalls: [ToolCall] = []
        var usage = Usage()
        var finish: FinishReason?
    }

    private var isStopping: Bool { stopRequested || Task.isCancelled }

    private func runLoop(task: String) async -> AgentOutcome {
        let startedAt = Date()
        currentTask = task
        runSteps = 0
        runUsage = Usage()
        emitter.emit(.started(task: task))
        await approvalGate.setMode(policy.approvalMode)
        let setup = await prepareRun(task: task)

        var first = ChatMessage.user(task)
        if setup.vision, setup.hasDesktop, policy.initialScreenshot, !isStopping, let computer = setup.computer, let surface {
            if let shot = try? await computer.captureScreenshot(from: surface) {
                first.parts.append(.image(shot))
                emitter.emit(.screenshot(shot))
            }
        }
        transcript.append(first)

        let (outcome, finalStatus) = await loop(setup: setup, control: RunControl())
        return await finish(task: task, outcome: outcome, status: finalStatus, startedAt: startedAt)
    }

    private func loop(setup: RunSetup, control: RunControl) async -> (AgentOutcome, AgentStatus) {
        while true {
            if isStopping { return (stoppedOutcome(), .stopped) }
            await waitIfPaused()
            if isStopping { return (stoppedOutcome(), .stopped) }
            injectQueuedMessages()

            if runSteps >= policy.maxSteps {
                let summary = "Stopped after \(policy.maxSteps) steps without finishing the task."
                emitter.emit(.error(summary))
                return (outcome(success: false, summary), .failed)
            }
            runSteps += 1
            await manageContext(setup)
            transition(to: .thinking)

            let step: StepResult
            do {
                step = try await Self.streamStep(client: client, messages: modelMessages(setup), tools: setup.toolSpecs,
                                                 options: policy.generation, emitter: emitter)
            } catch {
                if isStopping || error is CancellationError { return (stoppedOutcome(), .stopped) }
                let message = Self.describe(error)
                emitter.emit(.error(message))
                return (outcome(success: false, message), .failed)
            }
            runUsage = runUsage + step.usage
            totalUsage = totalUsage + step.usage
            if step.usage != Usage() { emitter.emit(.usage(step.usage)) }

            var calls = resolveCalls(step, setup: setup)
            var resultNote: String?
            if setup.textMode, calls.count > 1 {
                // Text protocol: one action per reply. Run the first and say so.
                calls = [calls[0]]
                resultNote = "Only the first action was run. Reply with exactly one fenced JSON block per message."
            }
            let assistant = assistantMessage(step, calls: calls, textMode: setup.textMode)
            if !assistant.parts.isEmpty {
                transcript.append(assistant)
                emitter.emit(.message(assistant))
            }
            if isStopping { return (stoppedOutcome(), .stopped) }

            if calls.isEmpty {
                if setup.textMode, Self.looksLikeToolAttempt(step.text) {
                    // A malformed action block: ask again (counts as a step).
                    let retry = ChatMessage.user(Self.unparsableActionMessage)
                    transcript.append(retry)
                    emitter.emit(.message(retry))
                    continue
                }
                // A plain answer ends the run, unless the user said something meanwhile.
                if !queuedMessages.isEmpty { continue }
                let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    let summary = "The model returned an empty reply."
                    emitter.emit(.error(summary))
                    return (outcome(success: false, summary), .failed)
                }
                return (outcome(success: true, text), .finished)
            }

            transition(to: .acting)
            let batches = Self.batches(for: calls, registry: setup.registry)
            var results: [ToolResult] = []
            for (call, batch) in zip(calls, batches) {
                let completed = await control.completion != nil
                let halted = await control.haltReason != nil
                if isStopping || completed || halted {
                    let why = completed ? "was completed" : "was stopped"
                    results.append(ToolResult(callID: call.id, text: "Skipped: the run \(why) before this call.", isError: true))
                    continue
                }
                await waitIfPaused()
                emitter.emit(.toolCall(call))
                let result = await execute(call, registry: setup.registry, control: control, batch: batch)
                emitter.emit(.toolResult(result))
                for image in result.images { emitter.emit(.screenshot(image)) }
                results.append(result)
            }
            appendToolResults(results, calls: calls, textMode: setup.textMode, note: resultNote)

            if let reason = await control.haltReason {
                emitter.emit(.error(reason))
                return (outcome(success: false, reason), .stopped)
            }
            if let done = await control.completion {
                return (outcome(success: done.success, done.summary), .finished)
            }
            if policy.stepDelay > 0, !isStopping {
                try? await Task.sleep(nanoseconds: UInt64(policy.stepDelay * 1_000_000_000))
            }
        }
    }

    private func finish(task: String, outcome: AgentOutcome, status finalStatus: AgentStatus, startedAt: Date) async -> AgentOutcome {
        paused = false
        let waiters = pauseWaiters
        pauseWaiters.removeAll()
        for w in waiters { w.resume() }
        transition(to: finalStatus, force: true)
        emitter.emit(.finished(outcome))
        lastOutcome = outcome
        currentTask = nil
        loopTask = nil
        if let sink = episodeSink {
            let episode = AgentEpisode(agentID: id, agentName: name, model: client.model, task: task, transcript: transcript,
                                       outcome: outcome, startedAt: startedAt, endedAt: Date())
            let em = emitter
            // Detached so that a stopped (cancelled) run still records its episode.
            await Task.detached {
                do { try await sink.record(episode) } catch { em.emit(.note("Could not record the episode: \(error)")) }
            }.value
        }
        return outcome
    }

    private func outcome(success: Bool, _ summary: String) -> AgentOutcome {
        AgentOutcome(success: success, summary: summary, steps: runSteps, usage: runUsage)
    }

    private func stoppedOutcome() -> AgentOutcome { outcome(success: false, "Stopped by the user.") }

    // MARK: Steps

    private func prepareRun(task: String) async -> RunSetup {
        let caps = client.capabilities
        let textMode: Bool
        switch policy.toolCallMode {
        case .auto: textMode = !caps.tools
        case .native: textMode = false
        case .text: textMode = true
        }

        var info: SurfaceInfo?
        var modelSize: PixelSize?
        var computer: ComputerTool?
        if let surface {
            info = await surface.info
            let display = await surface.displaySize
            let scaler = ScreenshotScaler(maxLongEdge: policy.screenshotMaxEdge)
            let size = scaler.mapping(for: display, resizing: imageResizer.canResize).modelSize
            modelSize = size
            computer = ComputerTool(scaler: scaler, resizer: imageResizer, settleDelay: policy.actionSettleDelay, modelDisplaySize: size)
        }

        var registry: ToolRegistry
        if let customTools {
            registry = customTools
            computer = customTools.tool(named: ComputerTool.toolName) as? ComputerTool
        } else {
            registry = .standard(computer: computer, hasSurface: surface != nil, hasMemory: memory != nil)
        }
        registry.register(extraTools)

        // Native computer use: the explicit bridge, or the default one for the model's native tool kind.
        var nativeComputer = false
        if policy.useNativeComputerUse, !textMode,
           let bridge = nativeBridge ?? NativeComputerBridges.bridge(for: caps.nativeComputerUse),
           caps.nativeComputerUse == bridge.kind,
           let computer, let modelSize, registry.contains(ComputerTool.toolName) {
            registry.remove(named: ComputerTool.toolName)
            let features = ComputerFeatures(zoom: computer.resizer.canCrop, heldKeys: true)
            registry.register(NativeComputerTool(bridge: bridge, computer: computer, modelDisplaySize: modelSize, features: features))
            nativeComputer = true
        }

        var memoryBlock: String?
        if let memory, let provider = memoryContext {
            memoryBlock = await provider.contextBlock(for: task, store: memory)
        }

        let specs = registry.specs
        let prompt = SystemPromptBuilder(agentName: name, instructions: instructions, surfaceInfo: info, screenSize: modelSize,
                                         memoryContext: memoryBlock, tools: specs, textToolMode: textMode,
                                         vision: caps.vision, nativeComputer: nativeComputer).build()
        var budget = policy.tokenBudget
        if let window = caps.contextWindow, window > 0 { budget = min(budget, window * 3 / 4) }
        let context = ContextManager(keepScreenshots: policy.keepScreenshots, tokenBudget: budget)
        return RunSetup(registry: registry, toolSpecs: textMode ? [] : specs, systemPrompt: prompt, textMode: textMode,
                        vision: caps.vision, hasDesktop: info?.hasDesktop ?? false, computer: computer,
                        parser: TextToolCallParser(knownTools: Set(registry.names)), context: context)
    }

    private func manageContext(_ setup: RunSetup) async {
        transcript = setup.context.pruneScreenshots(transcript)
        guard setup.context.needsCompaction(transcript),
              transcript.count > setup.context.keepRecentMessages + 3 else { return }
        emitter.emit(.note("Summarising older steps to stay within the context budget."))
        do {
            transcript = try await setup.context.compact(transcript, using: client)
        } catch {
            emitter.emit(.note("Could not summarise the context: \(Self.describe(error))"))
        }
    }

    private func modelMessages(_ setup: RunSetup) -> [ChatMessage] {
        let messages = [ChatMessage.system(setup.systemPrompt)] + transcript
        return setup.vision ? messages : ContextManager.stripImages(messages)
    }

    static func streamStep(client: any LLMClient, messages: [ChatMessage], tools: [ToolSpec],
                           options: GenerationOptions, emitter: AgentEmitter) async throws -> StepResult {
        var r = StepResult()
        for try await event in client.stream(messages: messages, tools: tools, options: options) {
            switch event {
            case .textDelta(let d):
                r.text += d
                emitter.emit(.textDelta(d))
            case .reasoningDelta(let d):
                r.reasoning += d
                emitter.emit(.reasoningDelta(d))
            case .toolCall(let call):
                r.toolCalls.append(call)
            case .usage(let u):
                r.usage = r.usage + u
            case .finished(let f):
                r.finish = f
            case .toolCallStart, .toolCallDelta:
                break
            }
        }
        return r
    }

    /// Tool calls of a step (parsed from text in text mode), with unique non-empty ids.
    private func resolveCalls(_ step: StepResult, setup: RunSetup) -> [ToolCall] {
        var calls = step.toolCalls
        if setup.textMode, calls.isEmpty {
            calls = setup.parser.parse(step.text, idPrefix: "call_\(runCount)_\(runSteps)").calls
        }
        var seen = Set<String>()
        var out: [ToolCall] = []
        for (i, call) in calls.enumerated() {
            var c = call
            if c.id.isEmpty || seen.contains(c.id) { c.id = "call_\(runCount)_\(runSteps)_\(i)" }
            seen.insert(c.id)
            out.append(c)
        }
        return out
    }

    private func assistantMessage(_ step: StepResult, calls: [ToolCall], textMode: Bool) -> ChatMessage {
        var parts: [ContentPart] = []
        if !step.reasoning.isEmpty { parts.append(.reasoning(step.reasoning)) }
        if !step.text.isEmpty { parts.append(.text(step.text)) }
        if !textMode { parts += calls.map { ContentPart.toolUse($0) } }
        return ChatMessage(role: .assistant, parts: parts)
    }

    private func appendToolResults(_ results: [ToolResult], calls: [ToolCall], textMode: Bool, note: String? = nil) {
        guard !results.isEmpty else { return }
        guard textMode else {
            transcript.append(.toolResults(results))
            return
        }
        // Models without tool calling get results as a user message.
        var parts: [ContentPart] = []
        for (call, result) in zip(calls, results) {
            let body = result.text.isEmpty ? "(no text output)" : result.text
            parts.append(.text("Result of \(call.name)\(result.isError ? " (error)" : ""): \(body)"))
            parts += result.images.map { ContentPart.image($0) }
        }
        if let note { parts.append(.text(note)) }
        transcript.append(ChatMessage(role: .user, parts: parts))
    }

    private func execute(_ call: ToolCall, registry: ToolRegistry, control: RunControl, batch: ToolBatch?) async -> ToolResult {
        let ctx = ToolContext(agentID: id, agentName: name, surface: surface, memory: memory, emitter: emitter,
                              approval: approvalGate, scratchDirectory: scratchDirectory, userInput: userInput,
                              control: control, batch: batch)
        return await registry.execute(call, ctx: ctx, onApprovalWait: { waiting in
            await self.approvalWaitChanged(waiting)
        })
    }

    /// Groups this turn's calls by the tool they route to and gives each its position in that group.
    static func batches(for calls: [ToolCall], registry: ToolRegistry) -> [ToolBatch] {
        let names = calls.map { registry.resolvedName($0.name) ?? $0.name }
        var counts: [String: Int] = [:]
        for n in names { counts[n, default: 0] += 1 }
        var states: [String: ToolBatchState] = [:]
        var seen: [String: Int] = [:]
        var out: [ToolBatch] = []
        for n in names {
            let state = states[n] ?? ToolBatchState()
            states[n] = state
            let index = seen[n, default: 0]
            seen[n] = index + 1
            out.append(ToolBatch(index: index, count: counts[n] ?? 1, state: state))
        }
        return out
    }

    static let unparsableActionMessage = "Could not parse an action. Reply with one fenced JSON block."

    /// Text that seems to contain a (malformed) action block rather than a final answer.
    static func looksLikeToolAttempt(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("```json") || t.contains("<tool_call>") || t.contains("<|python_tag|>")
            || (t.contains("\"tool\"") && t.contains("{")) || (t.contains("\"arguments\"") && t.contains("{"))
    }

    private func approvalWaitChanged(_ waiting: Bool) {
        transition(to: waiting ? .waitingForApproval : .acting)
    }

    private func injectQueuedMessages() {
        guard !queuedMessages.isEmpty else { return }
        let texts = queuedMessages
        queuedMessages.removeAll()
        for text in texts {
            let message = ChatMessage.user(text)
            transcript.append(message)
            emitter.emit(.message(message))
        }
    }

    private func waitIfPaused() async {
        while paused && !isStopping {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                pauseWaiters.append(c)
            }
        }
    }

    /// Sets the status and emits it (while paused, remembers it for `resume()` instead).
    private func transition(to new: AgentStatus, force: Bool = false) {
        if paused && !force {
            statusBeforePause = new
            return
        }
        guard status != new else { return }
        status = new
        emitter.emit(.status(new))
    }

    static func describe(_ error: Error) -> String {
        if let z = error as? ZError { return z.description }
        return String(describing: error)
    }
}
