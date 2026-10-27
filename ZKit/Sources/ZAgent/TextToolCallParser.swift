import Foundation
import ZCore

/// Fallback tool calling for models without native tools: the system prompt asks for a fenced
/// ```json {"tool": "...", "arguments": {...}} ``` block, and this parser digs calls out of the reply.
///
/// Lenient on purpose. It accepts:
/// * fences with any or no language tag, unterminated fences, one-line fences;
/// * `<tool_call>…</tool_call>` tags (Hermes / Qwen style);
/// * bare JSON objects in prose when no fenced call was found;
/// * name keys `tool` / `name` / `tool_name` / `function` (string or `{name, arguments}`);
/// * argument keys `arguments` / `args` / `parameters` / `input` / `params`, given as an object or a JSON string,
///   or flat (`{"tool": "shell", "command": "ls"}`);
/// * arrays of calls and `{"tool_calls": [...]}`; trailing commas and smart quotes.
public struct TextToolCallParser: Sendable {
    public struct Parsed: Hashable, Sendable {
        public var calls: [ToolCall]
        /// The reply with the tool-call blocks removed.
        public var prose: String
        public init(calls: [ToolCall], prose: String) { self.calls = calls; self.prose = prose }
    }

    /// When non-empty, bare (unfenced) JSON objects are only accepted if they name one of these tools.
    public var knownTools: Set<String>

    public init(knownTools: Set<String> = []) { self.knownTools = knownTools }

    static let nameKeys = ["tool", "name", "tool_name", "function", "action_name"]
    static let argumentKeys = ["arguments", "args", "parameters", "input", "params", "tool_input"]

    public func parse(_ text: String, idPrefix: String = "call") -> Parsed {
        var calls: [ToolCall] = []
        var removals: [Range<String.Index>] = []

        // 1. Fenced blocks and <tool_call> tags: accept explicit calls, or any call to a known tool.
        var blocks = Self.fencedBlocks(in: text)
        let tagged = Self.taggedBlocks(in: text, tag: "tool_call") + Self.taggedBlocks(in: text, tag: "function_call")
            + Self.delimitedBlocks(in: text, open: "<|python_tag|>", closes: ["<|eom_id|>", "<|eot_id|>"])
        for b in tagged where !blocks.contains(where: { $0.range.overlaps(b.range) }) {
            blocks.append(b)
        }
        for block in blocks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let found = Self.candidates(fromJSONText: block.content)
                .filter { $0.explicit || knownTools.isEmpty || knownTools.contains($0.call.name) }
            if !found.isEmpty { calls += found.map(\.call); removals.append(block.range) }
        }
        // 2. Bare JSON objects in prose, only when nothing was fenced. Stricter: known tool, or explicit when unknown.
        if calls.isEmpty {
            for object in Self.balancedObjects(in: text) {
                let found = Self.candidates(fromJSONText: String(text[object]))
                    .filter { knownTools.isEmpty ? $0.explicit : knownTools.contains($0.call.name) }
                if !found.isEmpty { calls += found.map(\.call); removals.append(object) }
            }
        }

        calls = calls.enumerated().map { i, call in ToolCall(id: "\(idPrefix)_\(i)", name: call.name, arguments: call.arguments) }

        var prose = ""
        var last = text.startIndex
        for r in removals.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.lowerBound >= last {
            prose += text[last..<r.lowerBound]
            last = r.upperBound
        }
        prose += text[last...]
        return Parsed(calls: calls, prose: prose.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The instructions appended to the system prompt in text mode.
    public static func formatInstructions(tools: [ToolSpec]) -> String {
        let names = tools.map(\.name).joined(separator: "|")
        var s = """
        ## How to call tools
        You can act only by replying with exactly ONE fenced JSON block and nothing after it:
        ```json
        {"tool": "<\(names)>", "arguments": { ... }}
        ```
        Put any reasoning BEFORE the block, in at most two sentences. Wait for the result before the next action.

        Available tools:
        """
        for t in tools {
            s += "\n- \(t.name): \(t.description)\n  arguments schema: \(t.parameters.jsonString())"
        }
        return s
    }

    // MARK: - Interpreting JSON

    /// A call found in JSON. `explicit` = the object clearly meant a tool call (a "tool" key, an arguments key,
    /// or an OpenAI-style "function" object) rather than merely having a "name".
    struct Candidate {
        var call: ToolCall
        var explicit: Bool
    }

    /// Calls in a JSON text (object, array of objects, or {"tool_calls": [...]}).
    static func candidates(fromJSONText raw: String) -> [Candidate] {
        guard let value = lenientParse(raw) else { return [] }
        return candidates(from: value)
    }

    static func candidates(from value: JSONValue) -> [Candidate] {
        switch value {
        case .array(let items):
            return items.flatMap { candidates(from: $0) }
        case .object(let o):
            if let list = o["tool_calls"]?.arrayValue ?? o["calls"]?.arrayValue {
                return list.flatMap { candidates(from: $0) }.map { Candidate(call: $0.call, explicit: true) }
            }
            if let c = candidate(from: o) { return [c] }
            return []
        default:
            return []
        }
    }

    static func candidate(from o: [String: JSONValue]) -> Candidate? {
        var name: String?
        var args: JSONValue?
        var explicit = false
        for key in nameKeys {
            guard let v = o[key] else { continue }
            if let s = v.stringValue, !s.isEmpty {
                name = s
                explicit = key == "tool" || key == "tool_name" || key == "function"
                break
            }
            if case .object(let f) = v, let s = f["name"]?.stringValue, !s.isEmpty {
                // OpenAI style {"function": {"name": ..., "arguments": "..."}}
                name = s
                args = f["arguments"] ?? f["parameters"] ?? f["args"]
                explicit = true
                break
            }
        }
        guard let toolName = name?.trimmingCharacters(in: .whitespaces), !toolName.isEmpty,
              toolName.count <= 64, !toolName.contains(" ") else { return nil }
        if args == nil, let key = argumentKeys.first(where: { o[$0] != nil }) {
            args = o[key]
            explicit = true
        }
        if args == nil {
            // Flat form: every other key is an argument.
            var flat = o
            for k in nameKeys + ["id", "type"] { flat[k] = nil }
            args = .object(flat)
        }
        var arguments = args ?? .object([:])
        if case .string(let s) = arguments {
            arguments = lenientParse(s) ?? .object(["input": .string(s)])
        }
        if case .null = arguments { arguments = .object([:]) }
        return Candidate(call: ToolCall(id: "", name: toolName, arguments: arguments), explicit: explicit)
    }

    /// JSON parse with repairs: smart quotes, trailing commas, surrounding prose.
    static func lenientParse(_ raw: String) -> JSONValue? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let v = try? JSONValue.parse(text) { return v }
        var repaired = text
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        repaired = removeTrailingCommas(repaired)
        if let v = try? JSONValue.parse(repaired) { return v }
        // The JSON may sit inside other text: try the first balanced object or array.
        if let r = balancedObjects(in: repaired).first {
            let inner = removeTrailingCommas(String(repaired[r]))
            if let v = try? JSONValue.parse(inner) { return v }
        }
        return nil
    }

    /// Removes commas directly before } or ] (outside strings).
    static func removeTrailingCommas(_ s: String) -> String {
        let chars = Array(s)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var inString = false
        var escaped = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: - Finding blocks

    struct Block {
        var range: Range<String.Index>
        var content: String
    }

    /// ``` fenced blocks; an unterminated fence runs to the end of the text.
    static func fencedBlocks(in text: String) -> [Block] {
        var blocks: [Block] = []
        var cursor = text.startIndex
        let fence = "```"
        while cursor < text.endIndex, let open = text.range(of: fence, range: cursor..<text.endIndex) {
            let afterOpen = open.upperBound
            let close = text.range(of: fence, range: afterOpen..<text.endIndex)
            let lineEnd = text[afterOpen...].firstIndex(of: "\n") ?? text.endIndex
            let content: Substring
            if let close, close.lowerBound <= lineEnd {
                // One-line fence: ```json {"tool": ...}```
                content = stripLanguageTag(text[afterOpen..<close.lowerBound])
            } else {
                let start = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
                let header = text[afterOpen..<lineEnd]
                let body = text[start..<(close?.lowerBound ?? text.endIndex)]
                // A header that is itself JSON ("```{...") belongs to the body.
                content = header.trimmingCharacters(in: .whitespaces).hasPrefix("{") || header.trimmingCharacters(in: .whitespaces).hasPrefix("[")
                    ? text[afterOpen..<(close?.lowerBound ?? text.endIndex)] : body
            }
            let end = close?.upperBound ?? text.endIndex
            blocks.append(Block(range: open.lowerBound..<end, content: String(content)))
            cursor = end
        }
        return blocks
    }

    private static func stripLanguageTag(_ s: Substring) -> Substring {
        let trimmed = s.drop(while: { $0.isWhitespace })
        guard let first = trimmed.first, first.isLetter else { return trimmed }
        let tag = trimmed.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        return trimmed.dropFirst(tag.count)
    }

    /// <tag>…</tag> blocks; an unterminated tag runs to the end.
    static func taggedBlocks(in text: String, tag: String) -> [Block] {
        var blocks: [Block] = []
        var cursor = text.startIndex
        let openTag = "<\(tag)>", closeTag = "</\(tag)>"
        while cursor < text.endIndex, let open = text.range(of: openTag, options: [.caseInsensitive], range: cursor..<text.endIndex) {
            let close = text.range(of: closeTag, options: [.caseInsensitive], range: open.upperBound..<text.endIndex)
            let content = text[open.upperBound..<(close?.lowerBound ?? text.endIndex)]
            let end = close?.upperBound ?? text.endIndex
            blocks.append(Block(range: open.lowerBound..<end, content: String(content)))
            cursor = end
        }
        return blocks
    }

    /// `open` … first of `closes` (or the end of the text), e.g. `<|python_tag|>{…}<|eom_id|>`.
    static func delimitedBlocks(in text: String, open openMark: String, closes: [String]) -> [Block] {
        var blocks: [Block] = []
        var cursor = text.startIndex
        while cursor < text.endIndex, let open = text.range(of: openMark, range: cursor..<text.endIndex) {
            let close = closes.compactMap { text.range(of: $0, range: open.upperBound..<text.endIndex) }
                .min(by: { $0.lowerBound < $1.lowerBound })
            let content = text[open.upperBound..<(close?.lowerBound ?? text.endIndex)]
            let end = close?.upperBound ?? text.endIndex
            blocks.append(Block(range: open.lowerBound..<end, content: String(content)))
            cursor = end
        }
        return blocks
    }

    /// Ranges of top-level balanced {...} objects (string- and escape-aware).
    static func balancedObjects(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                if depth > 0 { inString = true }
            } else if c == "{" {
                if depth == 0 { start = i }
                depth += 1
            } else if c == "}", depth > 0 {
                depth -= 1
                if depth == 0, let s = start {
                    result.append(s..<text.index(after: i))
                    start = nil
                }
            }
            i = text.index(after: i)
        }
        return result
    }
}
