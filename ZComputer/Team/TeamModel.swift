import Foundation
import Observation
import ZAgent
import ZCore
import ZMemory
import ZTeam

/// The Team screen: the member roster and goal (persisted as a ZTeam `TeamSpec` in Application Support), and one
/// `TeamRunner` per goal whose board, messages and phase feed the view. Member agent events go to the shared
/// `EventBus`, so the activity panel and the per-member lanes show them.
@Observable
@MainActor
final class TeamModel {
    var members: [TeamMember]
    var goal: String
    var maxParallelWorkers: Int
    var shellOutsideLease: Bool
    /// Give the team the Agent view's machine (Demo machine or a running VM).
    var useMachine = true

    private(set) var tasks: [TeamTask] = []
    private(set) var messages: [TeamMessage] = []
    private(set) var phase: TeamPhase = .idle
    private(set) var outcome: TeamOutcome?
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var lastError: String?

    let bus: EventBus
    let memory: SQLiteMemoryStore?
    let resizer: CoreGraphicsImageResizer

    @ObservationIgnored weak var resolver: (any ClientResolver)?
    @ObservationIgnored weak var machines: MachinesModel?
    @ObservationIgnored private var runner: TeamRunner?
    @ObservationIgnored private var feed: Task<Void, Never>?

    static var specURL: URL { AppPaths.supportDirectory.appendingPathComponent("team.json") }

    init(bus: EventBus, memory: SQLiteMemoryStore?, resizer: CoreGraphicsImageResizer) {
        self.bus = bus
        self.memory = memory
        self.resizer = resizer
        let saved = Self.loadSpec()
        let model = AgentSettings.modelRef() ?? ModelRef(provider: ProviderID(""), model: "")
        self.members = saved?.members ?? [
            TeamMember(name: "Ada", role: .lead, model: model, instructions: "Plan the work and write the final report."),
            TeamMember(name: "Ben", role: .worker, model: model),
            TeamMember(name: "Cleo", role: .reviewer, model: model, instructions: "Check every result carefully."),
        ]
        self.goal = saved?.goal ?? ""
        self.maxParallelWorkers = saved?.maxParallelWorkers ?? 2
        self.shellOutsideLease = saved?.shellOutsideLease ?? false
    }

    var currentSpec: TeamSpec {
        TeamSpec(members: members, goal: goal.trimmingCharacters(in: .whitespacesAndNewlines),
                 maxParallelWorkers: max(1, maxParallelWorkers), shellOutsideLease: shellOutsideLease,
                 defaultPolicy: AgentSettings.policy())
    }

    func tasks(in status: TaskStatus) -> [TeamTask] { tasks.filter { $0.status == status } }

    func memberName(_ id: String?) -> String {
        guard let id else { return "unassigned" }
        if id == TeamRoster.userID { return "User" }
        return members.first { $0.id == id }?.name ?? id
    }

    // MARK: Roster editing

    func addMember() {
        let model = members.last?.model ?? AgentSettings.modelRef() ?? ModelRef(provider: ProviderID(""), model: "")
        members.append(TeamMember(name: "Member \(members.count + 1)", role: .worker, model: model))
        save()
    }

    func removeMembers(at offsets: IndexSet) {
        members.remove(atOffsets: offsets)
        save()
    }

    func remove(_ member: TeamMember) {
        members.removeAll { $0.id == member.id }
        save()
    }

    /// Saves members, goal and options as `team.json`.
    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(currentSpec).write(to: Self.specURL, options: .atomic)
        } catch {
            lastError = "Could not save the team: \(Format.describe(error))"
        }
    }

    private static func loadSpec() -> TeamSpec? {
        guard let data = try? Data(contentsOf: specURL) else { return nil }
        return try? JSONDecoder().decode(TeamSpec.self, from: data)
    }

    // MARK: Running

    func run() {
        guard !isRunning else { return }
        let spec = currentSpec
        do {
            try spec.validate()
        } catch {
            lastError = Format.describe(error)
            return
        }
        if let missing = spec.members.first(where: { $0.model.model.isEmpty || $0.model.provider.rawValue.isEmpty }) {
            lastError = "Choose a model for \(missing.name)."
            return
        }
        save()
        lastError = nil
        tasks = []
        messages = []
        outcome = nil
        phase = .idle
        isRunning = true
        isPaused = false
        Task {
            do {
                let runner = try await makeRunner(spec)
                self.runner = runner
                subscribe(to: runner)
                let result = await runner.run()
                outcome = result
                if !result.success, tasks.isEmpty { lastError = result.report }
            } catch {
                lastError = Format.describe(error)
            }
            isRunning = false
            isPaused = false
        }
    }

    func pause() {
        guard let runner else { return }
        isPaused = true
        Task { await runner.pause() }
    }

    func resume() {
        guard let runner else { return }
        isPaused = false
        Task { await runner.resume() }
    }

    func stop() {
        guard let runner else { return }
        Task { await runner.stop() }
    }

    /// A message to one member (or to whoever is working when `to` is nil); answers `ask_user` questions too.
    func send(_ text: String, to memberID: String?) {
        guard let runner else { return }
        Task {
            let delivered = await runner.send(userMessage: text, to: memberID)
            if !delivered { lastError = "Nobody received the message (is the team running?)." }
        }
    }

    /// Approvals of team members, routed from the activity panel.
    func approve(_ request: ApprovalRequest, _ decision: ApprovalDecision) {
        guard let runner else { return }
        Task { await runner.approve(id: request.id, decision: decision, memberID: request.agentID) }
    }

    private func makeRunner(_ spec: TeamSpec) async throws -> TeamRunner {
        guard let resolver else { throw ZError.cancelled }
        // Clients are made up front on the main actor; the factory only hands them out.
        var clients: [String: any LLMClient] = [:]
        for member in spec.members {
            clients[member.id] = try await resolver.makeClient(for: member.model)
        }
        var surface: (any ComputerSurface)?
        if useMachine, let machines {
            surface = try machines.agentSurface()
            if surface != nil {
                let cloud = spec.members.filter { !resolver.isLocal($0.model.provider) }
                if let member = cloud.first(where: { !AgentSettings.hasCloudConsent($0.model.provider) }) {
                    throw ZError.approvalDenied("\(member.name) uses \(resolver.displayName(for: member.model)), which "
                        + "has not been allowed to receive screenshots. Run one task with it in the Agent view to give "
                        + "consent, use a local model, or turn off “Use the machine”.")
                }
            }
        }
        let fixed = clients
        let sink: (any EpisodeSink)? = memory.map { MemoryEpisodeSink(store: $0) }
        return TeamRunner(spec: spec, surface: surface, memory: memory, bus: bus, episodeSink: sink,
                          imageResizer: resizer) { member in
            guard let client = fixed[member.id] else {
                throw ZError.notFound("No model client for \(member.name)")
            }
            return client
        }
    }

    private func subscribe(to runner: TeamRunner) {
        feed?.cancel()
        let events = runner.teamEvents(replayHistory: true)
        feed = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: TeamEvent) {
        switch event {
        case .phase(let newPhase):
            phase = newPhase
        case .taskAdded(let task), .taskUpdated(let task):
            if let index = tasks.firstIndex(where: { $0.id == task.id }) {
                tasks[index] = task
            } else {
                tasks.append(task)
            }
        case .message(let message):
            messages.append(message)
        case .finished(let result):
            outcome = result
            tasks = result.tasks
        case .lease, .note:
            break
        }
    }
}
