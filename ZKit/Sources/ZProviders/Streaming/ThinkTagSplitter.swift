import Foundation
import ZCore

/// Splits streamed content that carries reasoning inline as `<think>…</think>` (quirk `thinkTagsInContent`, e.g.
/// MiniMax) into `.reasoningDelta` and `.textDelta` events. Tags split across chunks are handled.
public struct ThinkTagSplitter: Sendable {
    private static let open = "<think>"
    private static let close = "</think>"
    private var inThink = false
    private var pending = ""

    public init() {}

    public mutating func feed(_ chunk: String) -> [StreamEvent] {
        var text = pending + chunk
        pending = ""
        var events: [StreamEvent] = []
        while !text.isEmpty {
            let tag = inThink ? Self.close : Self.open
            if let range = text.range(of: tag) {
                let before = String(text[..<range.lowerBound])
                if !before.isEmpty { events.append(event(before)) }
                inThink.toggle()
                text = String(text[range.upperBound...])
                continue
            }
            // Keep a possible partial tag at the end for the next chunk.
            let keep = Self.partialSuffixLength(of: text, tag: tag)
            let emit = String(text.dropLast(keep))
            if !emit.isEmpty { events.append(event(emit)) }
            pending = String(text.suffix(keep))
            text = ""
        }
        return events
    }

    public mutating func flush() -> [StreamEvent] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [event(pending)]
    }

    private func event(_ text: String) -> StreamEvent {
        inThink ? .reasoningDelta(text) : .textDelta(text)
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `tag`.
    static func partialSuffixLength(of text: String, tag: String) -> Int {
        let maxLength = min(text.count, tag.count - 1)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) where tag.hasPrefix(String(text.suffix(length))) {
            return length
        }
        return 0
    }
}
