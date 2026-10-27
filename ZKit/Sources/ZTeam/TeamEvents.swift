import Foundation
import ZCore

/// Where the team is in its run.
public enum TeamPhase: String, Codable, Sendable, Hashable {
    case idle, planning, working, reviewing, reporting, finished, failed, stopped

    public var isFinal: Bool { self == .finished || self == .failed || self == .stopped }
}

/// Changes of the input lease on the shared machine. `holder` / `owner` are member ids.
public enum LeaseEvent: Sendable, Hashable, Codable {
    /// `holder` took the lease after waiting `waited` seconds.
    case acquired(holder: String, waited: TimeInterval)
    /// `holder` gave the lease back after `held` seconds.
    case released(holder: String, held: TimeInterval)
    /// The lease was taken back from `holder` after `held` seconds (the max hold time).
    case expired(holder: String, held: TimeInterval)
    /// `holder` is queued behind `owner` at `position` (1 = next in line).
    case waiting(holder: String, owner: String, position: Int)
}

/// A message between agents (or from the user). `from` / `to` are member ids (`TeamRoster.userID` for the user).
public struct TeamMessage: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var from: String
    /// Recipient member id; nil = everyone except the sender (broadcast).
    public var to: String?
    public var text: String
    public var date: Date

    public init(id: UUID = UUID(), from: String, to: String?, text: String, date: Date = Date()) {
        self.id = id; self.from = from; self.to = to; self.text = text; self.date = date
    }

    public var isBroadcast: Bool { to == nil }
}

/// Typed team activity for the Team view (board columns, message list, lease indicator).
public enum TeamEvent: Sendable, Hashable {
    case phase(TeamPhase)
    case taskAdded(TeamTask)
    case taskUpdated(TeamTask)
    case message(TeamMessage)
    case lease(LeaseEvent)
    case note(String)
    case finished(TeamOutcome)
}

/// One item of `TeamRunner.events()`: an agent's own event, or a team event.
public enum TeamFeedEvent: Sendable {
    case agent(AgentEventEnvelope)
    case team(TeamEvent)
}

// MARK: - Hub

/// Fan-out of `TeamEvent`s with a bounded history (the `EventBus` pattern, for team events).
public final class TeamEventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TeamEvent>.Continuation] = [:]
    private var historyBuffer: [TeamEvent] = []
    private let historyLimit: Int

    public init(historyLimit: Int = 2000) { self.historyLimit = max(0, historyLimit) }

    public func emit(_ event: TeamEvent) {
        lock.lock()
        historyBuffer.append(event)
        if historyBuffer.count > historyLimit { historyBuffer.removeFirst(historyBuffer.count - historyLimit) }
        let conts = Array(continuations.values)
        lock.unlock()
        for c in conts { c.yield(event) }
    }

    public var history: [TeamEvent] {
        lock.lock(); defer { lock.unlock() }
        return historyBuffer
    }

    /// Live events. The stream ends when the subscriber task is cancelled.
    public func subscribe(replayHistory: Bool = false) -> AsyncStream<TeamEvent> {
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

// MARK: - Reporter

/// Sends a team event to the hub and mirrors it onto the ZCore `EventBus` as a `.note` from the "Team"
/// pseudo-agent, so the activity panel shows board, message and lease changes.
public struct TeamReporter: Sendable {
    public let hub: TeamEventHub
    /// Nil = no mirroring onto an `EventBus`.
    public let emitter: AgentEmitter?
    /// Names for member ids in the notes.
    public let roster: TeamRoster

    public init(hub: TeamEventHub = TeamEventHub(), bus: (any EventSink)? = nil, agentID: String = "team",
                agentName: String = "Team", roster: TeamRoster = TeamRoster([])) {
        self.hub = hub
        self.emitter = bus.map { AgentEmitter(agentID: agentID, agentName: agentName, sink: $0) }
        self.roster = roster
    }

    /// The pseudo-agent id of the notes (nil when not mirroring).
    public var agentID: String? { emitter?.agentID }

    public func report(_ event: TeamEvent) {
        hub.emit(event)
        if let emitter, let note = noteText(for: event) { emitter.emit(.note(note)) }
    }

    /// The activity-panel line for an event (nil for events too frequent to show, such as lease hand-overs).
    public func noteText(for event: TeamEvent) -> String? {
        switch event {
        case .phase(let phase):
            switch phase {
            case .idle: return nil
            case .planning: return "The lead is planning the goal."
            case .working: return "Workers are on the tasks."
            case .reviewing: return "The reviewer is checking the results."
            case .reporting: return "The lead is writing the final report."
            case .finished: return "The team finished."
            case .failed: return "The team could not finish."
            case .stopped: return "The team was stopped."
            }
        case .taskAdded(let t):
            var s = "Task #\(t.id) added: \(Self.clip(t.title, 120))"
            if !t.dependsOn.isEmpty { s += " (after #\(t.dependsOn.joined(separator: ", #")))" }
            if let a = t.assignee { s += " → \(roster.name(of: a))" }
            return s
        case .taskUpdated(let t):
            var s = "Task #\(t.id) “\(Self.clip(t.title, 80))”: \(t.status.rawValue)"
            if let a = t.assignee { s += " (\(roster.name(of: a)))" }
            if let r = t.result, !r.isEmpty, t.status != .doing { s += " — \(Self.clip(r, 200))" }
            return s
        case .message(let m):
            let to = m.to.map { roster.name(of: $0) } ?? "everyone"
            return "\(roster.name(of: m.from)) → \(to): \(Self.clip(m.text, 300))"
        case .lease(let e):
            switch e {
            case .acquired, .released: return nil
            case .waiting(let holder, let owner, _):
                return "\(roster.name(of: holder)) is waiting for the screen (\(roster.name(of: owner)) is using it)."
            case .expired(let holder, let held):
                return "\(roster.name(of: holder)) held the screen for \(Int(held.rounded())) s; the lease was taken back."
            }
        case .note(let text):
            return text
        case .finished(let o):
            let done = o.tasks.filter { $0.status == .done }.count
            return "Team finished: \(done)/\(o.tasks.count) tasks done\(o.stopped ? " (stopped)" : "")."
        }
    }

    static func clip(_ text: String, _ max: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }
}
