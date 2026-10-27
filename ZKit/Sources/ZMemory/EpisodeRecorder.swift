import Foundation
import ZCore

/// Turns a finished agent run into an `episode` memory. The model writes a ≤5-line summary; when there is no client,
/// or the client fails or returns nothing, a heuristic summary (task, first user message, outcome) is used instead,
/// so recording only throws when the store itself fails.
public struct EpisodeRecorder: Sendable {
    public var maxSummaryLines: Int
    public var maxLineCharacters: Int
    /// The transcript sent to the model is cut to this size (keeping its start and end).
    public var maxTranscriptCharacters: Int
    /// Each transcript message is cut to this size.
    public var maxMessageCharacters: Int
    public var options: GenerationOptions

    public init(maxSummaryLines: Int = 5, maxLineCharacters: Int = 400, maxTranscriptCharacters: Int = 12_000,
                maxMessageCharacters: Int = 800, options: GenerationOptions = GenerationOptions(temperature: 0.2, maxTokens: 400)) {
        self.maxSummaryLines = max(1, maxSummaryLines)
        self.maxLineCharacters = max(20, maxLineCharacters)
        self.maxTranscriptCharacters = max(200, maxTranscriptCharacters)
        self.maxMessageCharacters = max(40, maxMessageCharacters)
        self.options = options
    }

    /// Convenience with the default settings.
    @discardableResult
    public static func record(task: String, transcript: [ChatMessage], outcome: AgentOutcome,
                              client: (any LLMClient)?, store: any MemoryStore) async throws -> MemoryItem {
        try await EpisodeRecorder().record(task: task, transcript: transcript, outcome: outcome, client: client, store: store)
    }

    @discardableResult
    public func record(task: String, transcript: [ChatMessage], outcome: AgentOutcome,
                       client: (any LLMClient)?, store: any MemoryStore) async throws -> MemoryItem {
        var summary: String?
        var summarizer = "heuristic"
        if let client {
            do {
                let result = try await client.complete(
                    messages: prompt(task: task, transcript: transcript, outcome: outcome), tools: [], options: options)
                summary = cleanSummary(result.message.text)
                if summary != nil { summarizer = client.model.description }
            } catch {
                summary = nil  // fall back to the heuristic summary below
            }
        }
        let text = summary ?? heuristicSummary(task: task, transcript: transcript, outcome: outcome)
        let now = Date()
        let item = MemoryItem(
            kind: .episode, title: title(task: task, transcript: transcript), text: text,
            tags: ["episode", outcome.success ? "success" : "failure"],
            source: client.map { "agent:\($0.model.description)" } ?? "agent",
            metadata: [
                "success": .bool(outcome.success),
                "steps": .number(Double(outcome.steps)),
                "inputTokens": .number(Double(outcome.usage.inputTokens)),
                "outputTokens": .number(Double(outcome.usage.outputTokens)),
                "summarizer": .string(summarizer),
            ],
            createdAt: now, updatedAt: now)
        try await store.save(item)
        return item
    }

    // MARK: Prompt

    func prompt(task: String, transcript: [ChatMessage], outcome: AgentOutcome) -> [ChatMessage] {
        let system = """
            You write memory notes for an AI agent that operates a computer. Summarise the run below in at most \
            \(maxSummaryLines) short lines of plain text: what was asked, what was done, the result, and anything worth \
            remembering next time (user preferences, facts about the environment, pitfalls). No preamble, no headings.
            """
        var request = "Task: \(TextUtil.oneLine(task))\n"
        request += "Outcome: \(outcome.success ? "succeeded" : "failed") after \(outcome.steps) step(s)."
        let report = TextUtil.trimmed(outcome.summary)
        if !report.isEmpty { request += "\nAgent's final report: \(TextUtil.truncate(report, 2_000))" }
        let condensed = condensedTranscript(transcript)
        if !condensed.isEmpty { request += "\n\nTranscript:\n\(condensed)" }
        return [.system(system), .user(request)]
    }

    /// One line per message (system prompts and reasoning left out), cut to fit, keeping the start and the end.
    func condensedTranscript(_ transcript: [ChatMessage]) -> String {
        let lines: [String] = transcript.compactMap { message in
            guard message.role != .system else { return nil }
            var parts: [String] = []
            for part in message.parts {
                switch part {
                case .text(let text): parts.append(text)
                case .image: parts.append("[image]")
                case .toolUse(let call): parts.append("[call \(call.name) \(call.arguments.jsonString())]")
                case .toolResult(let result):
                    parts.append("[result\(result.isError ? " (error)" : "")] \(result.text)\(result.images.isEmpty ? "" : " [image]")")
                case .reasoning: continue
                }
            }
            let body = TextUtil.oneLine(parts.joined(separator: " "))
            guard !body.isEmpty else { return nil }
            let speaker = message.name.map { "\(message.role.rawValue) (\($0))" } ?? message.role.rawValue
            return "\(speaker): \(TextUtil.truncate(body, maxMessageCharacters))"
        }
        let joined = lines.joined(separator: "\n")
        guard joined.count > maxTranscriptCharacters else { return joined }
        let head = maxTranscriptCharacters / 3
        let tail = maxTranscriptCharacters - head - 3
        return String(joined.prefix(head)) + "\n…\n" + String(joined.suffix(max(0, tail)))
    }

    /// Non-empty lines, at most `maxSummaryLines`, each cut to `maxLineCharacters`; nil when nothing is left.
    func cleanSummary(_ raw: String) -> String? {
        let lines = raw.split(whereSeparator: { $0.isNewline })
            .map { TextUtil.oneLine(String($0)) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") }
        guard !lines.isEmpty else { return nil }
        return lines.prefix(maxSummaryLines).map { TextUtil.truncate($0, maxLineCharacters) }.joined(separator: "\n")
    }

    func heuristicSummary(task: String, transcript: [ChatMessage], outcome: AgentOutcome) -> String {
        let taskLine = TextUtil.oneLine(task)
        let firstUser = transcript.first(where: { $0.role == .user }).map { TextUtil.oneLine($0.text) } ?? ""
        var lines: [String] = []
        if !taskLine.isEmpty { lines.append("Task: \(taskLine)") }
        if !firstUser.isEmpty, firstUser != taskLine { lines.append("Request: \(firstUser)") }
        lines.append("Outcome: \(outcome.success ? "succeeded" : "failed") after \(outcome.steps) step(s).")
        let report = TextUtil.oneLine(outcome.summary)
        if !report.isEmpty { lines.append("Result: \(report)") }
        return lines.prefix(maxSummaryLines).map { TextUtil.truncate($0, maxLineCharacters) }.joined(separator: "\n")
    }

    func title(task: String, transcript: [ChatMessage]) -> String {
        var subject = TextUtil.oneLine(task)
        if subject.isEmpty {
            subject = transcript.first(where: { $0.role == .user }).map { TextUtil.oneLine($0.text) } ?? ""
        }
        return subject.isEmpty ? "Episode" : "Episode: \(TextUtil.truncate(subject, 80))"
    }
}
