import Foundation
import ZCore

/// One row of the activity panel: an `AgentEventEnvelope` reduced for display (streamed deltas are merged into one
/// growing text row per agent).
struct ActivityItem: Identifiable {
    enum Kind {
        case started(String)
        case status(AgentStatus)
        case text(String)
        case reasoning(String)
        case userMessage(String)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case screenshot(ImageData)
        case approval(ApprovalRequest)
        case note(String)
        case usage(Usage)
        case finished(AgentOutcome)
        case error(String)
    }

    let id: UUID
    let agentID: String
    let agentName: String
    let timestamp: Date
    var kind: Kind

    var isDelta: Bool {
        switch kind {
        case .text, .reasoning: return true
        default: return false
        }
    }
}

/// One line of the chat transcript (main agent only).
struct ChatLine: Identifiable, Hashable {
    enum Role: Hashable { case user, assistant, system, error }

    let id: UUID
    var role: Role
    var text: String
    var timestamp: Date
    /// Still receiving streamed text.
    var live: Bool

    init(role: Role, text: String, live: Bool = false) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.timestamp = Date()
        self.live = live
    }
}

/// An agent seen on the bus (for the activity filter).
struct AgentRef: Identifiable, Hashable {
    var id: String
    var name: String
}

/// An `ask_user` question waiting for the human.
struct PendingQuestion: Hashable {
    var callID: String
    var agentID: String
    var agentName: String
    var question: String
}

/// The consent sheet's request: the run waits until the user allows screenshots for this provider.
struct ConsentRequest: Identifiable {
    let id = UUID()
    let ref: ModelRef
    let providerName: String
    let machineName: String
    let task: String
}

extension AgentStatus {
    /// True while the agent works on the machine (shows the "Agent is controlling" indicator).
    var isWorking: Bool {
        switch self {
        case .thinking, .acting, .waitingForApproval: return true
        case .idle, .paused, .finished, .failed, .stopped: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .acting: return "Acting"
        case .waitingForApproval: return "Waiting for approval"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}
