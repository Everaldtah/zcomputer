import Foundation

/// One server-sent event.
public struct SSEEvent: Sendable, Hashable {
    /// The `event:` field; nil means the default type ("message").
    public var event: String?
    /// All `data:` lines of the event joined with "\n".
    public var data: String
    public var id: String?
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event; self.data = data; self.id = id; self.retry = retry
    }

    /// `data: [DONE]` (OpenAI-style end marker).
    public var isDone: Bool { data.trimmingCharacters(in: .whitespaces) == "[DONE]" }
}

/// Incremental `text/event-stream` parser (WHATWG rules): LF, CR and CRLF line endings (also split across chunks),
/// `:` comments, `event:` / `data:` / `id:` / `retry:` fields, multi-line data, one optional space after the colon,
/// a leading BOM, and UTF-8 sequences split across chunks. `finish()` flushes a final event that was not followed
/// by a blank line (lenient: real servers often close the stream right after the last `data:` line).
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var sawFirstLine = false
    private var eventType: String?
    private var dataLines: [String] = []
    private var hasData = false
    private var lastEventID: String?
    private var retry: Int?

    public init() {}

    public mutating func feed(_ text: String) -> [SSEEvent] { feed(Data(text.utf8)) }

    public mutating func feed(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in data {
            if lastWasCR {
                lastWasCR = false
                if byte == 0x0A { continue }   // the LF of a CRLF whose CR already ended the line
            }
            switch byte {
            case 0x0D:
                lastWasCR = true
                processLine(&events)
            case 0x0A:
                processLine(&events)
            default:
                line.append(byte)
            }
        }
        return events
    }

    /// Call at end of stream.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty { processLine(&events) }
        lastWasCR = false
        dispatch(&events)
        return events
    }

    private mutating func processLine(_ events: inout [SSEEvent]) {
        var text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        if !sawFirstLine {
            sawFirstLine = true
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        }
        if text.isEmpty {
            dispatch(&events)
            return
        }
        if text.hasPrefix(":") { return }   // comment / keep-alive
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event":
            eventType = String(value)
        case "data":
            dataLines.append(String(value))
            hasData = true
        case "id":
            if !value.unicodeScalars.contains(where: { $0.value == 0 }) { lastEventID = String(value) }
        case "retry":
            if let ms = Int(value) { retry = ms }
        default:
            break
        }
    }

    private mutating func dispatch(_ events: inout [SSEEvent]) {
        defer {
            eventType = nil
            dataLines.removeAll()
            hasData = false
        }
        guard hasData else { return }
        let type = (eventType?.isEmpty ?? true) ? nil : eventType
        events.append(SSEEvent(event: type, data: dataLines.joined(separator: "\n"), id: lastEventID, retry: retry))
    }
}

/// Splits a byte stream into lines (NDJSON). Handles LF and CRLF, UTF-8 split across chunks; skips blank lines.
public struct LineSplitter: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                emit(&lines)
            } else {
                buffer.append(byte)
            }
        }
        return lines
    }

    public mutating func finish() -> [String] {
        var lines: [String] = []
        emit(&lines)
        return lines
    }

    private mutating func emit(_ lines: inout [String]) {
        if buffer.last == 0x0D { buffer.removeLast() }
        let text = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        buffer.removeAll(keepingCapacity: true)
        if !text.isEmpty { lines.append(text) }
    }
}
