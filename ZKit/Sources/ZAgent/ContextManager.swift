import Foundation
import ZCore

/// Keeps the transcript within the model's means: only the last N screenshots stay as images, and older turns
/// are summarised (with the model itself) once the estimated token count passes a budget.
public struct ContextManager: Sendable {
    public static let omittedScreenshot = "[screenshot omitted]"
    public static let omittedNoVision = "[image omitted: this model cannot see images]"

    /// Screenshots (images) kept as images, newest first.
    public var keepScreenshots: Int
    /// Estimated tokens above which `compact` summarises older turns. Nil disables summarising.
    public var tokenBudget: Int?
    /// Messages kept verbatim at the end when compacting.
    public var keepRecentMessages: Int

    public init(keepScreenshots: Int = 3, tokenBudget: Int? = 100_000, keepRecentMessages: Int = 8) {
        self.keepScreenshots = keepScreenshots
        self.tokenBudget = tokenBudget
        self.keepRecentMessages = keepRecentMessages
    }

    // MARK: Screenshots

    /// Replaces every image except the newest `keepScreenshots` with "[screenshot omitted]"
    /// (inside tool results too).
    public func pruneScreenshots(_ messages: [ChatMessage]) -> [ChatMessage] {
        var remaining = max(0, keepScreenshots)
        var out = messages
        for mi in out.indices.reversed() {
            var parts = out[mi].parts
            var changed = false
            for pi in parts.indices.reversed() {
                switch parts[pi] {
                case .image:
                    if remaining > 0 { remaining -= 1 } else { parts[pi] = .text(Self.omittedScreenshot); changed = true }
                case .toolResult(var result):
                    var resultChanged = false
                    for ri in result.parts.indices.reversed() {
                        guard case .image = result.parts[ri] else { continue }
                        if remaining > 0 { remaining -= 1 } else { result.parts[ri] = .text(Self.omittedScreenshot); resultChanged = true }
                    }
                    if resultChanged { parts[pi] = .toolResult(result); changed = true }
                default:
                    break
                }
            }
            if changed { out[mi].parts = parts }
        }
        return out
    }

    /// Replaces all images (for models without vision).
    public static func stripImages(_ messages: [ChatMessage], placeholder: String = omittedNoVision) -> [ChatMessage] {
        messages.map { m in
            var m = m
            m.parts = m.parts.map { part in
                switch part {
                case .image: return .text(placeholder)
                case .toolResult(var r):
                    r.parts = r.parts.map { if case .image = $0 { return .text(placeholder) } else { return $0 } }
                    return .toolResult(r)
                default: return part
                }
            }
            return m
        }
    }

    // MARK: Token estimate

    /// Rough token estimate: ~4 characters per token for text and JSON, images by area (≈ w·h/750, capped).
    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    public static func estimateTokens(_ message: ChatMessage) -> Int {
        4 + message.parts.reduce(0) { $0 + estimateTokens($1) }
    }

    static func estimateTokens(_ part: ContentPart) -> Int {
        switch part {
        case .text(let t), .reasoning(let t):
            return (t.utf8.count + 3) / 4
        case .image(let img):
            guard let w = img.width, let h = img.height, w > 0, h > 0 else { return 1_500 }
            return min(max(w * h / 750, 85), 2_500)
        case .toolUse(let call):
            return (call.name.utf8.count + call.arguments.jsonString().utf8.count + 3) / 4 + 8
        case .toolResult(let r):
            return 8 + r.parts.reduce(0) { $0 + estimateTokens($1) }
        }
    }

    public func needsCompaction(_ messages: [ChatMessage]) -> Bool {
        guard let budget = tokenBudget else { return false }
        return Self.estimateTokens(messages) > budget
    }

    // MARK: Summarising

    /// Summarises everything but the first message (the task) and the last `keepRecentMessages` into one
    /// user message, using `client`. Never splits a tool call from its results. Returns the messages unchanged
    /// when there is nothing worth compacting.
    public func compact(_ messages: [ChatMessage], using client: any LLMClient,
                        options: GenerationOptions = GenerationOptions(temperature: 0.2, maxTokens: 1_200)) async throws -> [ChatMessage] {
        guard let split = splitIndex(messages) else { return messages }
        let head = Array(messages[..<split])
        let recent = Array(messages[split...])

        let prompt: [ChatMessage] = [
            .system("""
            You compress the working transcript of an AI agent that operates a computer. Write a concise summary \
            (at most 15 short bullet points) that lets the agent continue without the old messages: the task, what has \
            been done, what worked and what failed, the current state of the machine (open windows, files, paths, \
            settings), facts learned, and the next steps. Plain text only.
            """),
            .user(Self.render(head)),
        ]
        let result = try await client.complete(messages: prompt, tools: [], options: options)
        let summary = result.message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw ZError.decoding("The model returned an empty summary.") }

        var intro = ""
        if let first = messages.first, first.role == .user, !first.text.isEmpty {
            intro = "Original task: \(first.text)\n\n"
        }
        let summaryText = intro + "Summary of the earlier steps (older messages were compacted to save context):\n" + summary
        var out = recent
        if let r0 = out.first, r0.role == .user {
            out[0].parts.insert(.text(summaryText + "\n\n---\n"), at: 0)
        } else {
            out.insert(ChatMessage(role: .user, parts: [.text(summaryText)]), at: 0)
        }
        return out
    }

    /// Where the kept tail starts, or nil when compaction would not remove anything.
    func splitIndex(_ messages: [ChatMessage]) -> Int? {
        let keep = max(1, keepRecentMessages)
        guard messages.count > keep + 1 else { return nil }
        var split = messages.count - keep
        // Do not start the tail with tool results whose call would be summarised away.
        while split > 1, messages[split].role == .tool { split -= 1 }
        guard split > 1 else { return nil }
        return split
    }

    /// Text rendering of messages for the summariser (images and long outputs elided).
    static func render(_ messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for m in messages {
            for part in m.parts {
                switch part {
                case .text(let t):
                    lines.append("[\(m.role.rawValue)] " + TextLimits.truncate(t, max: 4_000).text)
                case .reasoning(let t):
                    lines.append("[\(m.role.rawValue) thinking] " + TextLimits.truncate(t, max: 1_000).text)
                case .image:
                    lines.append("[\(m.role.rawValue)] [image]")
                case .toolUse(let call):
                    lines.append("[tool call \(call.name)] " + TextLimits.truncate(call.arguments.jsonString(), max: 1_000).text)
                case .toolResult(let r):
                    let text = r.text.isEmpty ? "(no text)" : TextLimits.truncate(r.text, max: 2_000).text
                    lines.append("[tool result\(r.isError ? " ERROR" : "")] " + text + (r.images.isEmpty ? "" : " [+\(r.images.count) image]"))
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
