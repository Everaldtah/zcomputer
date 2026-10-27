import Foundation
import ZCore

/// When the user must approve a tool call before it runs.
public enum ApprovalMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Never ask (fully autonomous).
    case never
    /// Ask only for destructive calls (rm -rf, mkfs, dd, shutdown, curl | sh, writes to system paths ...).
    case destructiveOnly
    /// Ask for every call that changes something (everything except read-only calls such as screenshots).
    case always
}

/// Human-in-the-loop gate. `request` emits `.approvalRequested` and suspends until `decide(id:decision:)`;
/// `.approveAlways` allows that kind of call without asking for the rest of the session.
public actor ApprovalGate {
    public private(set) var mode: ApprovalMode
    /// Kinds (see `ToolRisk.kind`) the user allowed for the session with "Always".
    public private(set) var alwaysAllowedKinds: Set<String> = []

    private let emitter: AgentEmitter?
    private var pending: [String: Pending] = [:]
    private var order: [String] = []

    private struct Pending {
        var request: ApprovalRequest
        var kind: String
        var emitter: AgentEmitter?
        var continuation: CheckedContinuation<ApprovalDecision, Never>
    }

    public init(mode: ApprovalMode = .destructiveOnly, emitter: AgentEmitter? = nil) {
        self.mode = mode
        self.emitter = emitter
    }

    public func setMode(_ mode: ApprovalMode) { self.mode = mode }

    /// Requests waiting for a decision, oldest first.
    public var pendingRequests: [ApprovalRequest] { order.compactMap { pending[$0]?.request } }

    /// Whether a call with this risk has to be approved under the current mode and session grants.
    public func needsApproval(_ risk: ToolRisk) -> Bool {
        if alwaysAllowedKinds.contains(risk.kind) { return false }
        switch mode {
        case .never: return false
        case .destructiveOnly: return risk.level == .destructive
        case .always: return risk.level != .readOnly
        }
    }

    /// Emits `.approvalRequested` and waits for the user's decision. Returns `.deny` when the waiting task is
    /// cancelled or `cancelAll()` is called. `.approveAlways` adds `kind` to the session grants.
    public func request(_ request: ApprovalRequest, kind: String, emitter: AgentEmitter? = nil) async -> ApprovalDecision {
        if alwaysAllowedKinds.contains(kind) { return .approve }
        if Task.isCancelled { return .deny }
        if pending[request.id] != nil {
            // Same id twice (a confused provider): refuse the duplicate rather than leaking a continuation.
            return .deny
        }
        let em = emitter ?? self.emitter
        let id = request.id
        em?.emit(.approvalRequested(request))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ApprovalDecision, Never>) in
                pending[id] = Pending(request: request, kind: kind, emitter: em, continuation: c)
                order.append(id)
            }
        } onCancel: {
            Task { await self.decide(id: id, decision: .deny) }
        }
    }

    /// Resolves a pending request. Returns false when no request with that id is waiting.
    @discardableResult
    public func decide(id: String, decision: ApprovalDecision) -> Bool {
        guard let p = pending.removeValue(forKey: id) else { return false }
        order.removeAll { $0 == id }
        if decision == .approveAlways { alwaysAllowedKinds.insert(p.kind) }
        p.emitter?.emit(.approvalResolved(id: id, decision: decision))
        p.continuation.resume(returning: decision)
        return true
    }

    /// Denies everything that is waiting (used by stop()).
    public func cancelAll() {
        for id in order { decide(id: id, decision: .deny) }
    }

    /// Grants a kind for the session without a pending request (e.g. from settings).
    public func allowAlways(kind: String) { alwaysAllowedKinds.insert(kind) }

    /// Forgets the session grants.
    public func resetSession() { alwaysAllowedKinds.removeAll() }
}
