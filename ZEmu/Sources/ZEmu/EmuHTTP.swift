import Foundation
import ZCore

/// A parsed HTTP `Range` request header against a resource of known size (RFC 9110 §14).
public enum EmuByteRange: Sendable, Hashable {
    /// No usable Range header: send the whole resource (200).
    case full
    /// Bytes `start...end` (inclusive) (206).
    case partial(start: UInt64, end: UInt64)
    /// The range starts beyond the end (416).
    case unsatisfiable

    /// Parses `bytes=a-b`, `bytes=a-` and `bytes=-n`. Only the first range of a multi-range request is honoured
    /// (v86 never sends more than one). Malformed headers are ignored, as RFC 9110 allows.
    public static func parse(_ header: String?, size: UInt64) -> EmuByteRange {
        guard let header else { return .full }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = trimmed.dropFirst(6)
        guard let first = spec.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) else { return .full }
        let parts = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return .full }
        let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
        if a.isEmpty {
            // Suffix range: the last n bytes.
            guard let n = UInt64(b) else { return .full }
            guard n > 0, size > 0 else { return .unsatisfiable }
            let start = n >= size ? 0 : size - n
            return .partial(start: start, end: size - 1)
        }
        guard let start = UInt64(a) else { return .full }
        var end: UInt64
        if b.isEmpty {
            end = size &- 1
        } else {
            guard let e = UInt64(b), e >= start else { return .full }
            end = e
        }
        guard start < size else { return .unsatisfiable }
        end = min(end, size - 1)
        return .partial(start: start, end: end)
    }
}

/// The head of a response for a file (or a byte range of it) and which bytes to send.
public struct EmuFileResponse: Sendable, Hashable {
    public var status: Int
    public var headers: [String: String]
    /// First byte of the file to send.
    public var offset: UInt64
    /// Number of bytes to send (0 for HEAD and 416).
    public var length: UInt64

    /// Builds the response for `method` (GET/HEAD) with an optional Range header.
    public static func make(method: String, rangeHeader: String?, fileSize: UInt64, contentType: String) -> EmuFileResponse {
        var headers: [String: String] = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Expose-Headers": "Content-Range, Content-Length, Accept-Ranges",
        ]
        let isHead = method.uppercased() == "HEAD"
        switch EmuByteRange.parse(rangeHeader, size: fileSize) {
        case .full:
            headers["Content-Length"] = String(fileSize)
            return EmuFileResponse(status: 200, headers: headers, offset: 0, length: isHead ? 0 : fileSize)
        case .partial(let start, let end):
            let length = end - start + 1
            headers["Content-Length"] = String(length)
            headers["Content-Range"] = "bytes \(start)-\(end)/\(fileSize)"
            return EmuFileResponse(status: 206, headers: headers, offset: start, length: isHead ? 0 : length)
        case .unsatisfiable:
            headers["Content-Length"] = "0"
            headers["Content-Range"] = "bytes */\(fileSize)"
            return EmuFileResponse(status: 416, headers: headers, offset: 0, length: 0)
        }
    }

    /// MIME type by file extension.
    public static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "svg": return "image/svg+xml"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}

/// Reads byte ranges from a file (thread-safe: each call opens its own handle).
public enum EmuFileReader {
    /// Reads up to `count` bytes at `offset`; returns fewer only at the end of the file.
    public static func read(_ url: URL, offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var out = Data()
        out.reserveCapacity(count)
        var remaining = count
        while remaining > 0 {
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
            out.append(chunk)
            remaining -= chunk.count
        }
        return out
    }

    /// The chunks (offset, length) a response body is sent in.
    public static func chunks(offset: UInt64, length: UInt64, chunkSize: Int) -> [(offset: UInt64, length: Int)] {
        guard length > 0, chunkSize > 0 else { return [] }
        var out: [(offset: UInt64, length: Int)] = []
        var at = offset
        let end = offset + length
        while at < end {
            let n = Int(min(UInt64(chunkSize), end - at))
            out.append((offset: at, length: n))
            at += UInt64(n)
        }
        return out
    }
}
