import Foundation
import Observation
import ZAgent
import ZCore
import ZMemory

/// The Agent view's state: one `AgentRunner` ("main") on the selected machine with the selected model, plus the
/// activity feed of every agent on the shared `EventBus` (team members included).
@Observable
@MainActor
final class AgentSession {
    static let mainAgentID = "main"
    static let activityLimit = 2000

    private(set) var chat: [ChatLine] = []
    private(set) var activity: [ActivityItem] = []
    private(set) var statuses: [String: AgentStatus] = [:]
    /// Agent id → name, in order of first appearance (the activity filter).
    private(set) var agents: [AgentRef] = []
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var resolvedApprovals: [String: ApprovalDecision] = [:]
    private(set) var pendingQuestion: PendingQuestion?
    /// From the first event of a run until its `.finished`.
    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var latestScreenshot: ImageData?
    /// The machine the current run controls (shown in the "Agent is controlling" overlay).
    private(set) var controlledMachineName: String?
    var consentRequest: ConsentRequest?
    /// Activity filter: nil = every agent.
    var agentFilter: String?

    let bus: EventBus
    let memory: SQLiteMemoryStore?
    let resizer: CoreGraphicsImageResizer

    @ObservationIgnored weak var resolver: (any ClientResolver)?
    @ObservationIgnored weak var machines: MachinesModel?
    @ObservationIgnored weak var team: TeamModel?
    @ObservationIgnored private var runner: AgentRunner?
    @ObservationIgnored private var runnerKey: String?
    @ObservationIgnored private var subscription: Task<Void, Never>?

    init(bus: EventBus, memory: SQLiteMemoryStore?, resizer: CoreGraphicsImageResizer) {
        self.bus = bus
        self.memory = memory
        self.resizer = resizer
        let stream = bus.subscribe(replayHistory: true)
        subscription = Task { [weak self] in
            for await envelope in stream {
                guard let self else { return }
                self.handle(envelope)
            }
        }
    }

    var mainStatus: AgentStatus { statuses[Self.mainAgentID] ?? .idle }

    /// True while the main agent works on a machine.
    var isControllingMachine: Bool { isRunning && controlledMachineName != nil && mainStatus.isWorking }

    var isPaused: Bool { mainStatus == .paused }

    var filteredActivity: [ActivityItem] {
        guard let agentFilter else { return activity }
        return activity.filter { $0.agentID == agentFilter }
    }

    func activity(for agentID: String, limit: Int = 60) -> [ActivityItem] {
        Array(activity.filter { $0.agentID == agentID }.suffix(limit))
    }

    // MARK: Commands

    /// The composer: starts a run, or (while running) answers `ask_user` / queues a message for the agent.
    func submit(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastError = nil
        if isRunning, let runner {
            Task { await runner.send(userMessage: text) }
            return
        }
        guard let ref = AgentSettings.modelRef() else {
            lastError = "Choose a model first: Settings ▸ Providers (cloud) or Settings ▸ Local models."
            return
        }
        let machineName = machines?.agentMachineName
        if let machineName, let resolver, !resolver.isLocal(ref.provider), !AgentSettings.hasCloudConsent(ref.provider) {
            let providerName = resolver.displayName(for: ref)
            consentRequest = ConsentRequest(ref: ref, providerName: providerName, machineName: machineName, task: text)
            return
        }
        launch(task: text, ref: ref)
    }

    /// The consent sheet's answer.
    func resolveConsent(_ request: ConsentRequest, allow: Bool) {
        consentRequest = nil
        guard allow else {
            lastError = "Not started: screenshots of \(request.machineName) were not allowed to go to "
                + "\(request.providerName). Pick a local model, or detach the machine."
            return
        }
        AgentSettings.setCloudConsent(request.ref.provider, granted: true)
        launch(task: request.task, ref: request.ref)
    }

    func pause() {
        guard let runner else { return }
        Task { await runner.pause() }
    }

    func resume() {
        guard let runner else { return }
        Task { await runner.resume() }
    }

    func stop() {
        guard let runner else { return }
        Task { await runner.stop() }
    }

    /// Approve / Deny / Always allow, routed to the agent (or team member) that asked.
    func decide(_ request: ApprovalRequest, _ decision: ApprovalDecision) {
        if request.agentID == Self.mainAgentID, let runner {
            Task { await runner.approve(id: request.id, decision: decision) }
        } else if let team {
            team.approve(request, decision)
        }
    }

    /// Forgets the conversation (the next task starts fresh).
    func newConversation() {
        guard !isRunning else { return }
        if let runner { Task { await runner.reset() } }
        runner = nil
        runnerKey = nil
        chat.removeAll()
        lastError = nil
    }

    func clearActivity() {
        activity.removeAll()
        resolvedApprovals.removeAll()
        bus.clearHistory()
    }

    // MARK: Running

    private func launch(task: String, ref: ModelRef) {
        isRunning = true
        Task {
            do {
                let runner = try await prepareRunner(for: ref)
                await runner.start(task: task)
            } catch {
                isRunning = false
                controlledMachineName = nil
                lastError = Format.describe(error)
            }
        }
    }

    private func prepareRunner(for ref: ModelRef) async throws -> AgentRunner {
        let policy = AgentSettings.policy()
        let machineKey = machines?.agentChoiceKey ?? "none"
        let key = "\(ref.description)#\(machineKey)"
        controlledMachineName = machines?.agentMachineName
        if let runner, runnerKey == key {
            await runner.setPolicy(policy)
            return runner
        }
        guard let resolver else { throw ZError.cancelled }
        let client = try await resolver.makeClient(for: ref)
        let surface = try machines?.agentSurface()
        let sink: (any EpisodeSink)? = memory.map { MemoryEpisodeSink(store: $0) }
        let runner = AgentRunner(id: Self.mainAgentID, name: "Agent", client: client, surface: surface, memory: memory,
                                 policy: policy, bus: bus, episodeSink: sink, imageResizer: resizer,
                                 scratchDirectory: AppPaths.agentScratch)
        self.runner = runner
        runnerKey = key
        return runner
    }

    // MARK: Events

    private func handle(_ envelope: AgentEventEnvelope) {
        let id = envelope.agentID
        if !agents.contains(where: { $0.id == id }) { agents.append(AgentRef(id: id, name: envelope.agentName)) }
        let isMain = id == Self.mainAgentID

        switch envelope.event {
        case .started(let task):
            append(envelope, .started(task))
            if isMain {
                isRunning = true
                chat.append(ChatLine(role: .user, text: task))
            }
        case .status(let status):
            statuses[id] = status
            append(envelope, .status(status))
        case .textDelta(let delta):
            appendDelta(envelope, delta, reasoning: false)
            if isMain { appendChatDelta(delta) }
        case .reasoningDelta(let delta):
            appendDelta(envelope, delta, reasoning: true)
        case .message(let message):
            if message.role == .user {
                append(envelope, .userMessage(message.text))
                if isMain { chat.append(ChatLine(role: .user, text: message.text)) }
            } else if message.role == .assistant, isMain {
                finishChatLine(with: message.text)
            }
        case .toolCall(let call):
            append(envelope, .toolCall(call))
            if call.name == "ask_user" {
                let question = call.arguments["question"]?.stringValue ?? call.arguments["text"]?.stringValue ?? "?"
                pendingQuestion = PendingQuestion(callID: call.id, agentID: id, agentName: envelope.agentName,
                                                  question: question)
                if isMain { chat.append(ChatLine(role: .system, text: "The agent asks: \(question)")) }
            }
        case .toolResult(let result):
            append(envelope, .toolResult(result))
            if pendingQuestion?.callID == result.callID { pendingQuestion = nil }
        case .screenshot(let image):
            append(envelope, .screenshot(image))
            latestScreenshot = image
        case .approvalRequested(let request):
            append(envelope, .approval(request))
            if !pendingApprovals.contains(where: { $0.id == request.id }) { pendingApprovals.append(request) }
        case .approvalResolved(let requestID, let decision):
            resolvedApprovals[requestID] = decision
            pendingApprovals.removeAll { $0.id == requestID }
        case .usage(let usage):
            append(envelope, .usage(usage))
        case .note(let note):
            append(envelope, .note(note))
        case .finished(let outcome):
            append(envelope, .finished(outcome))
            pendingApprovals.removeAll { $0.agentID == id }
            if pendingQuestion?.agentID == id { pendingQuestion = nil }
            if isMain {
                isRunning = false
                controlledMachineName = nil
                finishChatLine(with: nil)
                let prefix = outcome.success ? "Done" : "Not finished"
                chat.append(ChatLine(role: .system, text: "\(prefix) after \(outcome.steps) steps: \(outcome.summary)"))
            }
        case .error(let message):
            append(envelope, .error(message))
            if isMain { chat.append(ChatLine(role: .error, text: message)) }
        }
    }

    private func append(_ envelope: AgentEventEnvelope, _ kind: ActivityItem.Kind) {
        activity.append(ActivityItem(id: envelope.id, agentID: envelope.agentID, agentName: envelope.agentName,
                                     timestamp: envelope.timestamp, kind: kind))
        if activity.count > Self.activityLimit { activity.removeFirst(activity.count - Self.activityLimit) }
    }

    /// Merges a streamed delta into this agent's latest text row when nothing else came in between.
    private func appendDelta(_ envelope: AgentEventEnvelope, _ delta: String, reasoning: Bool) {
        if let index = activity.lastIndex(where: { $0.agentID == envelope.agentID }), index == activity.count - 1 {
            switch activity[index].kind {
            case .text(let text) where !reasoning:
                activity[index].kind = .text(text + delta)
                return
            case .reasoning(let text) where reasoning:
                activity[index].kind = .reasoning(text + delta)
                return
            default:
                break
            }
        }
        append(envelope, reasoning ? .reasoning(delta) : .text(delta))
    }

    private func appendChatDelta(_ delta: String) {
        if let last = chat.indices.last, chat[last].role == .assistant, chat[last].live {
            chat[last].text += delta
        } else {
            chat.append(ChatLine(role: .assistant, text: delta, live: true))
        }
    }

    /// Ends the streaming assistant line; `text` (the complete message) replaces the streamed text when given.
    private func finishChatLine(with text: String?) {
        if let last = chat.indices.last, chat[last].role == .assistant, chat[last].live {
            if let text, !text.isEmpty { chat[last].text = text }
            chat[last].live = false
        } else if let text, !text.isEmpty {
            chat.append(ChatLine(role: .assistant, text: text))
        }
    }
}
