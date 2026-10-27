import Foundation
import ZCore

/// Turns provider error responses into honest `ZError`s that carry the provider's own message.
public enum ProviderErrorMapper {
    /// The human-readable message in an error body: `error.message` (OpenAI, Anthropic, Gemini, prefixed with the
    /// error code/type/status), `error` as a string (Ollama), `message`, or `detail` (FastAPI style servers);
    /// otherwise the raw text (truncated).
    public static func message(from body: Data) -> String {
        if let json = try? JSONValue.parse(body), let message = message(from: json) {
            return message
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "(empty response body)" }
        return String(text.prefix(600))
    }

    public static func message(from json: JSONValue) -> String? {
        if case .array(let items) = json, let first = items.first { return message(from: first) }
        if let error = json["error"] {
            if let text = error.stringValue { return text }
            if let text = error["message"]?.stringValue {
                let code = error["code"]?.stringValue ?? error["status"]?.stringValue ?? error["type"]?.stringValue
                if let code, !code.isEmpty, !text.hasPrefix(code) { return "\(code): \(text)" }
                return text
            }
            if let nested = message(from: error) { return nested }
        }
        if let text = json["message"]?.stringValue { return text }
        if let detail = json["detail"] {
            if let text = detail.stringValue { return text }
            if let items = detail.arrayValue {
                let parts = items.compactMap { $0["msg"]?.stringValue ?? $0.stringValue }
                if !parts.isEmpty { return parts.joined(separator: "; ") }
            }
        }
        return nil
    }

    /// Seconds to wait from `retry-after-ms`, `retry-after` (seconds or an HTTP date), or a Gemini `RetryInfo`.
    public static func retryAfter(headers: [String: String], body: Data, now: Date = Date()) -> Double? {
        if let ms = headers["retry-after-ms"].flatMap({ Double($0.trimmingCharacters(in: .whitespaces)) }) {
            return max(0, ms / 1000)
        }
        if let value = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            if let seconds = Double(value) { return max(0, seconds) }
            if let date = parseHTTPDate(value) { return max(0, date.timeIntervalSince(now)) }
        }
        // Gemini: {"error": {"details": [{"@type": "...RetryInfo", "retryDelay": "12s"}]}}
        if let json = try? JSONValue.parse(body), let details = json["error"]?["details"]?.arrayValue {
            for detail in details {
                guard let type = detail["@type"]?.stringValue, type.hasSuffix("RetryInfo"),
                      let delay = detail["retryDelay"]?.stringValue else { continue }
                let trimmed = delay.hasSuffix("s") ? String(delay.dropLast()) : delay
                if let seconds = Double(trimmed) { return max(0, seconds) }
            }
        }
        return nil
    }

    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// True when a 429 means "out of quota / credit" rather than "slow down" (retrying would not help).
    public static func isQuotaExhausted(message: String) -> Bool {
        let lower = message.lowercased()
        return ["insufficient_quota", "exceeded your current quota", "billing", "credit balance", "out of credits",
                "insufficient credit", "payment required", "quota exceeded for"].contains { lower.contains($0) }
    }

    /// The `ZError` for a non-2xx response.
    public static func error(status: Int, headers: [String: String], body: Data) -> ZError {
        let message = message(from: body)
        if status == 429, !isQuotaExhausted(message: message) {
            return .rateLimited(retryAfter: retryAfter(headers: headers, body: body))
        }
        return .http(status: status, body: message)
    }

    /// The `ZError` for an error object that arrives inside a 200 stream (`{"error": {...}}` / `event: error`).
    public static func streamError(_ json: JSONValue) -> ZError {
        let error = json["error"] ?? json
        let message = message(from: ["error": error]) ?? error.jsonString()
        let type = (error["type"]?.stringValue ?? error["code"]?.stringValue ?? error["status"]?.stringValue ?? "").lowercased()
        if type.contains("rate_limit") || type.contains("resource_exhausted") {
            return isQuotaExhausted(message: message) ? .http(status: 429, body: message) : .rateLimited(retryAfter: nil)
        }
        var status = error["code"]?.intValue ?? 0
        if !(400...599).contains(status) {
            if type.contains("overloaded") { status = 529 }
            else if type.contains("invalid_request") || type.contains("invalid_argument") { status = 400 }
            else if type.contains("authentication") || type.contains("unauthenticated") { status = 401 }
            else if type.contains("permission") { status = 403 }
            else if type.contains("not_found") { status = 404 }
            else { status = 500 }
        }
        return .http(status: status, body: message)
    }
}
