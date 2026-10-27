import Foundation

public enum AgentStatus: String, Codable, Sendable, Hashable {
    case idle, thinking, acting, waitingForApproval, paused, finished, failed, stopped
}

public struct ApprovalRequest: Hashable, Codable, Sendable, Identifiable {
    public var id: String          // the tool call id
    public var agentID: String
    public var toolName: String
    public var summary: String
    public var arguments: JSONValue
    public init(id: String, agentID: String, toolName: String, summary: String, arguments: JSONValue) {
        self.id = id; self.agentID = agentID; self.toolName = toolName; self.summary = summary; self.arguments = arguments
    }
}

public enum ApprovalDecision: String, Codable, Sendable, Hashable {
    case approve, deny, approveAlways
}

public struct AgentOutcome: Hashable, Codable, Sendable {
    public var success: Bool
    public var summary: String
    public var steps: Int
    public var usage: Usage
    public init(success: Bool, summary: String, steps: Int, usage: Usage) {
        self.success = success; self.summary = summary; self.steps = steps; self.usage = usage
    }
}

/// Everything that shows up in the "what is the agent doing" panel.
public enum AgentEvent: Sendable, Hashable, Codable {
    case started(task: String)
    case status(AgentStatus)
    /// Streaming assistant text (deltas).
    case textDelta(String)
    /// Streaming reasoning text (deltas).
    case reasoningDelta(String)
    /// A complete message appended to the transcript.
    case message(ChatMessage)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// A screenshot the agent looked at (already downscaled for the model).
    case screenshot(ImageData)
    case approvalRequested(ApprovalRequest)
    case approvalResolved(id: String, decision: ApprovalDecision)
    case usage(Usage)
    case note(String)
    case finished(AgentOutcome)
    case error(String)
}

public struct AgentEventEnvelope: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var agentID: String
    public var agentName: String
    public var timestamp: Date
    public var event: AgentEvent
    public init(id: UUID = UUID(), agentID: String, agentName: String, timestamp: Date = Date(), event: AgentEvent) {
        self.id = id; self.agentID = agentID; self.agentName = agentName; self.timestamp = timestamp; self.event = event
    }
}

public protocol EventSink: Sendable {
    func emit(_ envelope: AgentEventEnvelope)
}

/// Fan-out event bus with a bounded history, safe to subscribe to from the UI.
public final class EventBus: EventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AgentEventEnvelope>.Continuation] = [:]
    private var historyBuffer: [AgentEventEnvelope] = []
    private let historyLimit: Int

    public init(historyLimit: Int = 2000) { self.historyLimit = historyLimit }

    public func emit(_ envelope: AgentEventEnvelope) {
        lock.lock()
        historyBuffer.append(envelope)
        if historyBuffer.count > historyLimit { historyBuffer.removeFirst(historyBuffer.count - historyLimit) }
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(envelope) }
    }

    public var history: [AgentEventEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return historyBuffer
    }

    public func clearHistory() {
        lock.lock(); historyBuffer.removeAll(); lock.unlock()
    }

    /// Subscribe to live events. The stream ends when the subscriber task is cancelled.
    public func subscribe(replayHistory: Bool = false) -> AsyncStream<AgentEventEnvelope> {
        let id = UUID()
        return AsyncStream { continuation in
            self.lock.lock()
            let replay = replayHistory ? self.historyBuffer : []
            self.continuations[id] = continuation
            self.lock.unlock()
            for e in replay { continuation.yield(e) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.continuations[id] = nil; self.lock.unlock()
            }
        }
    }
}

/// Convenience for emitting from an agent.
public struct AgentEmitter: Sendable {
    public let agentID: String
    public let agentName: String
    public let sink: EventSink
    public init(agentID: String, agentName: String, sink: EventSink) { self.agentID = agentID; self.agentName = agentName; self.sink = sink }
    public func emit(_ event: AgentEvent) {
        sink.emit(AgentEventEnvelope(agentID: agentID, agentName: agentName, event: event))
    }
}
