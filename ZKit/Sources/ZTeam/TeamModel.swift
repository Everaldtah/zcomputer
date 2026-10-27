import Foundation
import ZCore
import ZAgent

// MARK: - Roles and members

/// What a member does in the team. Custom roles do board work like workers (the name is shown to the model).
public enum TeamRole: Hashable, Sendable, Codable, CustomStringConvertible {
    case lead
    case worker
    case reviewer
    case custom(String)

    /// Lenient: "lead"/"leader"/"planner", "worker", "reviewer"/"critic"; anything else is a custom role.
    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "lead", "leader", "planner": self = .lead
        case "worker": self = .worker
        case "reviewer", "review", "critic": self = .reviewer
        default: self = .custom(trimmed)
        }
    }

    public var rawValue: String {
        switch self {
        case .lead: return "lead"
        case .worker: return "worker"
        case .reviewer: return "reviewer"
        case .custom(let name): return name
        }
    }

    public var description: String { rawValue }

    /// Workers and custom roles take tasks from the board.
    public var doesTaskWork: Bool {
        switch self {
        case .worker, .custom: return true
        case .lead, .reviewer: return false
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.init(rawValue: try c.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// One agent of the team: its own model, instructions and (optionally) its own policy.
public struct TeamMember: Hashable, Codable, Sendable, Identifiable {
    /// Also the `AgentRunner` id (and so the `agentID` of its events).
    public var id: String
    public var name: String
    public var role: TeamRole
    public var model: ModelRef
    /// Extra instructions for this member (added to its system prompt).
    public var instructions: String
    /// Replaces the team's default policy for this member (nil = `TeamSpec.defaultPolicy`).
    public var policy: AgentPolicy?

    public init(id: String = UUID().uuidString, name: String, role: TeamRole, model: ModelRef,
                instructions: String = "", policy: AgentPolicy? = nil) {
        self.id = id; self.name = name; self.role = role; self.model = model
        self.instructions = instructions; self.policy = policy
    }

    private enum CodingKeys: String, CodingKey { case id, name, role, model, instructions, policy }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(TeamRole.self, forKey: .role) ?? .worker
        model = try c.decode(ModelRef.self, forKey: .model)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        policy = try c.decodeIfPresent(AgentPolicy.self, forKey: .policy)
    }
}

// MARK: - Spec

/// A team and the goal it works on.
public struct TeamSpec: Hashable, Codable, Sendable {
    public var members: [TeamMember]
    public var goal: String
    /// Workers running a task at the same time (at least 1).
    public var maxParallelWorkers: Int
    /// When true, shell commands and file reads/writes do not wait for the input lease (they do not touch the
    /// screen or keyboard, so they can run while another agent types). Default false: everything that changes the
    /// machine is serialised.
    public var shellOutsideLease: Bool
    /// Longest time one agent may hold the input lease before it is taken back (seconds; 0 = no limit).
    public var leaseMaxHold: TimeInterval
    /// Attempts per task before it is marked failed (2 = one retry).
    public var maxAttemptsPerTask: Int
    /// Lets the reviewer reopen tasks (each at most once) for another round of work.
    public var allowReopen: Bool
    /// Policy for members without their own.
    public var defaultPolicy: AgentPolicy

    public init(members: [TeamMember], goal: String, maxParallelWorkers: Int = 2, shellOutsideLease: Bool = false,
                leaseMaxHold: TimeInterval = 30, maxAttemptsPerTask: Int = 2, allowReopen: Bool = true,
                defaultPolicy: AgentPolicy = AgentPolicy()) {
        self.members = members; self.goal = goal; self.maxParallelWorkers = maxParallelWorkers
        self.shellOutsideLease = shellOutsideLease; self.leaseMaxHold = leaseMaxHold
        self.maxAttemptsPerTask = maxAttemptsPerTask; self.allowReopen = allowReopen; self.defaultPolicy = defaultPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case members, goal, maxParallelWorkers, shellOutsideLease, leaseMaxHold, maxAttemptsPerTask, allowReopen, defaultPolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        members = try c.decode([TeamMember].self, forKey: .members)
        goal = try c.decodeIfPresent(String.self, forKey: .goal) ?? ""
        maxParallelWorkers = try c.decodeIfPresent(Int.self, forKey: .maxParallelWorkers) ?? 2
        shellOutsideLease = try c.decodeIfPresent(Bool.self, forKey: .shellOutsideLease) ?? false
        leaseMaxHold = try c.decodeIfPresent(TimeInterval.self, forKey: .leaseMaxHold) ?? 30
        maxAttemptsPerTask = try c.decodeIfPresent(Int.self, forKey: .maxAttemptsPerTask) ?? 2
        allowReopen = try c.decodeIfPresent(Bool.self, forKey: .allowReopen) ?? true
        defaultPolicy = try c.decodeIfPresent(AgentPolicy.self, forKey: .defaultPolicy) ?? AgentPolicy()
    }

    /// The planner and report writer: the first `.lead`, else the first member.
    public var lead: TeamMember? { members.first { $0.role == .lead } ?? members.first }

    /// The first `.reviewer` that is not also acting as the lead (nil = no review phase).
    public var reviewer: TeamMember? {
        let leadID = lead?.id
        return members.first { $0.role == .reviewer && $0.id != leadID }
    }

    /// Members that take tasks from the board: workers and custom roles, or the lead when there are none.
    public var workers: [TeamMember] {
        let w = members.filter { $0.role.doesTaskWork }
        if w.isEmpty, let lead { return [lead] }
        return w
    }

    public func member(id: String) -> TeamMember? { members.first { $0.id == id } }

    /// Throws `ZError.invalidArgument` for a spec that cannot run (no members, duplicate ids, empty goal).
    public func validate() throws {
        guard !members.isEmpty else { throw ZError.invalidArgument("The team has no members.") }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZError.invalidArgument("The team has no goal.")
        }
        var seen = Set<String>()
        for m in members {
            guard !m.id.isEmpty else { throw ZError.invalidArgument("A team member has an empty id.") }
            guard seen.insert(m.id).inserted else { throw ZError.invalidArgument("Two team members share the id '\(m.id)'.") }
        }
    }

    public var roster: TeamRoster { TeamRoster(members) }
}

// MARK: - Roster

/// Name / role lookup over the members (used by messages and tools).
public struct TeamRoster: Hashable, Sendable {
    public var members: [TeamMember]

    public init(_ members: [TeamMember]) { self.members = members }

    public func member(id: String) -> TeamMember? { members.first { $0.id == id } }

    /// Display name for a member id ("User" for the human, the id itself when unknown).
    public func name(of id: String) -> String {
        if id == TeamRoster.userID { return "User" }
        return member(id: id)?.name ?? id
    }

    /// Finds a member by id, by name (case-insensitive, an "@" prefix is ignored), or by role
    /// ("lead", "reviewer", or "worker" when there is exactly one).
    public func resolve(_ reference: String) -> TeamMember? {
        var ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if ref.hasPrefix("@") { ref.removeFirst() }
        guard !ref.isEmpty else { return nil }
        if let m = member(id: ref) { return m }
        let lower = ref.lowercased()
        if let m = members.first(where: { $0.name.lowercased() == lower }) { return m }
        if lower == "lead" || lower == "leader" { return members.first { $0.role == .lead } ?? members.first }
        let byRole = members.filter { $0.role.rawValue.lowercased() == lower }
        return byRole.count == 1 ? byRole.first : nil
    }

    /// "Ada (lead), Bob (worker)".
    public var summary: String {
        members.map { "\($0.name) (\($0.role.rawValue))" }.joined(separator: ", ")
    }

    /// Sender id used for messages from the human.
    public static let userID = "user"
}
