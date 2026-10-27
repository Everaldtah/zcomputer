import Foundation

/// Word tokenisation shared by the hashing embedder and keyword search.
enum TextTokenizer {
    /// Lower-cased runs of letters and digits.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Words without English stop words (all words when every word is a stop word).
    static func contentWords(_ text: String) -> [String] {
        let all = words(text)
        let content = all.filter { !stopwords.contains($0) }
        return content.isEmpty ? all : content
    }

    /// Distinct content words in order of appearance, for keyword queries.
    static func queryTerms(_ text: String, maxTerms: Int = 32) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for word in contentWords(text) where seen.insert(word).inserted {
            terms.append(word)
            if terms.count >= maxTerms { break }
        }
        return terms
    }

    static let stopwords: Set<String> = [
        "a", "about", "after", "all", "also", "an", "and", "any", "are", "as", "at", "be", "because", "been", "before",
        "between", "both", "but", "by", "can", "could", "did", "do", "does", "doesn", "don", "each", "for", "from", "had",
        "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its", "just", "me",
        "more", "most", "my", "no", "not", "of", "on", "or", "other", "our", "out", "over", "own", "s", "same", "she",
        "should", "so", "some", "such", "t", "than", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "to", "too", "under", "until", "up", "very", "was", "we", "were", "what", "when", "where", "which",
        "while", "who", "why", "will", "with", "would", "you", "your",
    ]

    // MARK: Stable hashing (Swift's Hasher is seeded per process, so it cannot be used for stored features)

    static let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325
    static let fnvPrime: UInt64 = 0x0000_0100_0000_01b3

    static func fnv1a<S: Sequence>(_ bytes: S, seed: UInt64) -> UInt64 where S.Element == UInt8 {
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* fnvPrime
        }
        return hash
    }

    /// splitmix64 finaliser: spreads FNV output over all bits.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e37_79b9_7f4a_7c15
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}

/// Small string helpers for compact prompt text.
enum TextUtil {
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses all whitespace (including newlines) to single spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Keeps line structure but collapses each line, joining lines with " / ".
    static func compactLines(_ text: String) -> String {
        text.split(whereSeparator: { $0.isNewline })
            .map { oneLine(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }

    /// Cuts to at most `limit` characters, ending with "…" when cut.
    static func truncate(_ text: String, _ limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        guard limit > 1 else { return "…" }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
