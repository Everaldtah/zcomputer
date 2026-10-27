import Foundation
import ZCore

/// Agent-to-agent messages. Each member has an inbox of unread messages: those sent to it, and broadcasts from
/// others. Messages are reported as `TeamEvent.message` (and as activity notes).
public actor MessageBus {
    public nonisolated let roster: TeamRoster
    public nonisolated let reporter: TeamReporter?

    private var log: [TeamMessage] = []
    private var readIDs: [String: Set<UUID>] = [:]

    /// Recipient names that mean "everyone".
    public static let broadcastNames: Set<String> = ["all", "everyone", "everybody", "team", "*", "@all", "@everyone"]

    public init(roster: TeamRoster, reporter: TeamReporter? = nil) {
        self.roster = roster
        self.reporter = reporter
    }

    /// Every message so far, oldest first.
    public var messages: [TeamMessage] { log }

    /// Sends `text` from `sender` (a member id or `TeamRoster.userID`) to one member, found by id, name or role
    /// ("all" / "everyone" broadcasts). Throws `ZError.notFound` for an unknown recipient and
    /// `ZError.invalidArgument` for an empty message or a message to oneself.
    @discardableResult
    public func send(from sender: String, to recipient: String, text: String) throws -> TeamMessage {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ZError.invalidArgument("The message is empty.") }
        if Self.broadcastNames.contains(recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return try broadcast(from: sender, text: body)
        }
        guard let member = roster.resolve(recipient) else {
            throw ZError.notFound("team member '\(recipient)'. The team: \(roster.summary)")
        }
        guard member.id != sender else { throw ZError.invalidArgument("That is you; send the message to a teammate.") }
        return append(TeamMessage(from: sender, to: member.id, text: body))
    }

    /// Sends `text` to every member except the sender.
    @discardableResult
    public func broadcast(from sender: String, text: String) throws -> TeamMessage {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ZError.invalidArgument("The message is empty.") }
        return append(TeamMessage(from: sender, to: nil, text: body))
    }

    /// Records a message that was delivered another way (e.g. the user's message handed straight to an agent):
    /// it shows in the log and the events but not in the recipient's inbox.
    @discardableResult
    public func record(from sender: String, to recipient: String?, text: String) -> TeamMessage {
        let message = TeamMessage(from: sender, to: recipient, text: text)
        if let recipient { readIDs[recipient, default: []].insert(message.id) }
        else { for m in roster.members { readIDs[m.id, default: []].insert(message.id) } }
        return append(message)
    }

    /// Unread messages for `member`, oldest first; marks them read unless `markRead` is false.
    public func inbox(for member: String, markRead: Bool = true) -> [TeamMessage] {
        let read = readIDs[member] ?? []
        let unread = log.filter { isFor(member, $0) && !read.contains($0.id) }
        if markRead, !unread.isEmpty { readIDs[member, default: []].formUnion(unread.map(\.id)) }
        return unread
    }

    public func unreadCount(for member: String) -> Int {
        let read = readIDs[member] ?? []
        return log.filter { isFor(member, $0) && !read.contains($0.id) }.count
    }

    /// "From Ada: text" / "From Ada (to everyone): text".
    public nonisolated func format(_ message: TeamMessage) -> String {
        let from = roster.name(of: message.from)
        return message.isBroadcast ? "From \(from) (to everyone): \(message.text)" : "From \(from): \(message.text)"
    }

    private func isFor(_ member: String, _ m: TeamMessage) -> Bool {
        if let to = m.to { return to == member }
        return m.from != member
    }

    private func append(_ message: TeamMessage) -> TeamMessage {
        log.append(message)
        reporter?.report(.message(message))
        return message
    }
}
