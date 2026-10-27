import Foundation

/// Splits long text into overlapping chunks for retrieval. Sizes are in estimated tokens (characters / 4 by
/// default). Chunks break at paragraph boundaries when possible, then at sentence boundaries, then at whitespace,
/// and only cut inside a word when there is no other choice.
public struct Chunker: Sendable, Hashable {
    public var targetTokens: Int
    public var overlapTokens: Int
    public var charactersPerToken: Int

    public init(targetTokens: Int = 800, overlapTokens: Int = 100, charactersPerToken: Int = 4) {
        self.targetTokens = max(1, targetTokens)
        self.overlapTokens = max(0, overlapTokens)
        self.charactersPerToken = max(1, charactersPerToken)
    }

    /// Hard upper bound on a chunk's length in characters.
    public var maxCharacters: Int { targetTokens * charactersPerToken }

    /// Characters carried over from the end of one chunk to the start of the next.
    public var overlapCharacters: Int { min(overlapTokens * charactersPerToken, maxCharacters / 2) }

    /// Rough token estimate (ceil(characters / charactersPerToken)).
    public static func estimateTokens(_ text: String, charactersPerToken: Int = 4) -> Int {
        let perToken = max(1, charactersPerToken)
        return (text.count + perToken - 1) / perToken
    }

    public func chunks(_ text: String) -> [String] {
        let trimmed = TextUtil.trimmed(text)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= maxCharacters { return [trimmed] }
        return pack(units(trimmed))
    }

    // MARK: Units

    /// A piece of text that is never split further; `separator` joins it to the unit before it.
    struct Unit: Hashable {
        var text: String
        var separator: String
        var length: Int

        init(text: String, separator: String) {
            self.text = text
            self.separator = separator
            self.length = text.count
        }
    }

    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]

    func units(_ text: String) -> [Unit] {
        var result: [Unit] = []
        for (paragraphIndex, paragraph) in paragraphs(text).enumerated() {
            let paragraphSeparator = paragraphIndex == 0 ? "" : "\n\n"
            if paragraph.count <= maxCharacters {
                result.append(Unit(text: paragraph, separator: paragraphSeparator))
                continue
            }
            var isFirst = true
            for sentence in sentences(paragraph) {
                for (pieceIndex, piece) in hardSplit(sentence.text).enumerated() {
                    let separator = isFirst ? paragraphSeparator : (pieceIndex == 0 ? sentence.separator : piece.separator)
                    result.append(Unit(text: piece.text, separator: separator))
                    isFirst = false
                }
            }
        }
        return result
    }

    /// Paragraphs are separated by blank lines.
    func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var lines: [Substring] = []
        func flush() {
            let paragraph = TextUtil.trimmed(lines.joined(separator: "\n"))
            if !paragraph.isEmpty { result.append(paragraph) }
            lines.removeAll()
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            if line.allSatisfy({ $0.isWhitespace }) {
                flush()
            } else {
                lines.append(line)
            }
        }
        flush()
        return result
    }

    /// Sentences end after a terminator followed by whitespace, or at a line break.
    func sentences(_ paragraph: String) -> [(text: String, separator: String)] {
        var result: [(text: String, separator: String)] = []
        var current = ""
        var pendingSeparator = " "
        func flush(boundary: String) {
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty {
                result.append((text: sentence, separator: result.isEmpty ? "" : pendingSeparator))
                pendingSeparator = boundary
            } else if boundary == "\n" {
                pendingSeparator = "\n"
            }
            current = ""
        }
        for character in paragraph {
            if character.isNewline {
                flush(boundary: "\n")
            } else if character.isWhitespace, let last = current.last, Self.sentenceTerminators.contains(last) {
                flush(boundary: " ")
            } else if character.isWhitespace && current.isEmpty {
                continue
            } else {
                current.append(character)
            }
        }
        flush(boundary: " ")
        return result
    }

    /// Splits text longer than a chunk at whitespace (or anywhere, for unbroken text). Pieces leave room for the
    /// overlap so consecutive pieces still share context.
    func hardSplit(_ text: String) -> [(text: String, separator: String)] {
        guard text.count > maxCharacters else { return [(text: text, separator: "")] }
        let limit = max(1, maxCharacters - overlapCharacters - 1)
        var pieces: [(text: String, separator: String)] = []
        var rest = Substring(text)
        var separator = ""
        while rest.count > limit {
            let window = rest.prefix(limit)
            var cut = window.endIndex
            var nextSeparator = ""
            if let space = window.lastIndex(where: { $0.isWhitespace }),
               window.distance(from: window.startIndex, to: space) >= limit / 2 {
                cut = space
                nextSeparator = " "
            }
            let piece = rest[rest.startIndex..<cut].trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append((text: piece, separator: separator)) }
            rest = rest[cut...].drop(while: { $0.isWhitespace })
            separator = nextSeparator
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { pieces.append((text: tail, separator: separator)) }
        return pieces
    }

    // MARK: Packing

    static func joinedLength(_ units: [Unit]) -> Int {
        var length = 0
        for (index, unit) in units.enumerated() {
            length += unit.length + (index == 0 ? 0 : unit.separator.count)
        }
        return length
    }

    static func render(_ units: [Unit]) -> String {
        var text = ""
        for (index, unit) in units.enumerated() {
            if index > 0 { text += unit.separator }
            text += unit.text
        }
        return text
    }

    func pack(_ units: [Unit]) -> [String] {
        var chunks: [String] = []
        var current: [Unit] = []
        var currentLength = 0
        for unit in units {
            let added = current.isEmpty ? unit.length : unit.separator.count + unit.length
            if !current.isEmpty && currentLength + added > maxCharacters {
                chunks.append(Self.render(current))
                current = overlap(after: current, before: unit)
            }
            current.append(unit)
            currentLength = Self.joinedLength(current)
        }
        if !current.isEmpty { chunks.append(Self.render(current)) }
        return chunks
    }

    /// The trailing units of `previous` (at most `overlapCharacters`) to repeat at the start of the next chunk.
    func overlap(after previous: [Unit], before next: Unit) -> [Unit] {
        let budget = overlapCharacters
        guard budget > 0, let last = previous.last else { return [] }
        var tail: [Unit] = []
        var length = 0
        for unit in previous.reversed() {
            let cost = unit.length + (tail.first.map { $0.separator.count } ?? 0)
            if length + cost > budget { break }
            tail.insert(unit, at: 0)
            length += cost
        }
        // Never repeat a whole chunk.
        if tail.count == previous.count { tail.removeFirst() }
        if tail.isEmpty, let suffix = Self.boundarySuffix(of: last.text, maxLength: budget) {
            tail = [Unit(text: suffix, separator: "")]
        }
        while !tail.isEmpty && Self.joinedLength(tail + [next]) > maxCharacters {
            tail.removeFirst()
        }
        return tail
    }

    /// The end of `text` (at most `maxLength` characters), starting at a sentence boundary when there is one,
    /// otherwise at a word boundary, otherwise wherever it falls.
    static func boundarySuffix(of text: String, maxLength: Int) -> String? {
        guard maxLength > 0, !text.isEmpty else { return nil }
        let suffix = text.suffix(maxLength)
        guard suffix.startIndex != text.startIndex else {
            let whole = TextUtil.trimmed(String(suffix))
            return whole.isEmpty ? nil : whole
        }
        var previous: Character?
        for index in suffix.indices {
            let character = suffix[index]
            if character.isWhitespace, let previous, sentenceTerminators.contains(previous) {
                let candidate = TextUtil.trimmed(String(suffix[index...]))
                if !candidate.isEmpty { return candidate }
                break
            }
            previous = character
        }
        if let space = suffix.firstIndex(where: { $0.isWhitespace }) {
            let candidate = TextUtil.trimmed(String(suffix[space...]))
            if !candidate.isEmpty { return candidate }
        }
        let raw = TextUtil.trimmed(String(suffix))
        return raw.isEmpty ? nil : raw
    }
}
