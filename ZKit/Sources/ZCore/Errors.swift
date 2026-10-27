import Foundation

public enum ZError: Error, Sendable, CustomStringConvertible, Equatable {
    case unsupported(String)
    case missingAPIKey(ProviderID)
    case http(status: Int, body: String)
    case decoding(String)
    case network(String)
    case rateLimited(retryAfter: Double?)
    case cancelled
    case vm(String)
    case guest(String)
    case tool(name: String, message: String)
    case approvalDenied(String)
    case invalidArgument(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .unsupported(let s): return "Unsupported: \(s)"
        case .missingAPIKey(let p): return "No API key for \(p.rawValue)"
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(600))"
        case .decoding(let s): return "Decoding error: \(s)"
        case .network(let s): return "Network error: \(s)"
        case .rateLimited(let r): return "Rate limited" + (r.map { " (retry after \($0)s)" } ?? "")
        case .cancelled: return "Cancelled"
        case .vm(let s): return "VM error: \(s)"
        case .guest(let s): return "Guest agent error: \(s)"
        case .tool(let n, let m): return "Tool \(n) failed: \(m)"
        case .approvalDenied(let s): return "Denied: \(s)"
        case .invalidArgument(let s): return "Invalid argument: \(s)"
        case .notFound(let s): return "Not found: \(s)"
        }
    }
}
