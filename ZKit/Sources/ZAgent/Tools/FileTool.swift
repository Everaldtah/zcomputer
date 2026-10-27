import Foundation
import ZCore

/// read_file / write_file / list_dir inside the machine, through the surface.
public struct FileTool: Tool {
    public enum Operation: String, Sendable, CaseIterable, Hashable {
        case readFile = "read_file"
        case writeFile = "write_file"
        case listDir = "list_dir"
    }

    public let operation: Operation
    /// Text characters returned by read_file before truncating.
    public var maxReadCharacters: Int

    public init(_ operation: Operation, maxReadCharacters: Int = 60_000) {
        self.operation = operation
        self.maxReadCharacters = maxReadCharacters
    }

    /// All three file tools.
    public static var all: [any Tool] { Operation.allCases.map { FileTool($0) } }

    public var spec: ToolSpec {
        switch operation {
        case .readFile:
            return ToolSpec(name: operation.rawValue,
                            description: "Read a file inside the machine. Text comes back as text; PNG/JPEG images come back as an image.",
                            parameters: Schema.object([
                                "path": Schema.string("Absolute path inside the machine."),
                                "max_chars": Schema.integer("Optional limit on returned characters."),
                            ], required: ["path"]))
        case .writeFile:
            return ToolSpec(name: operation.rawValue,
                            description: "Create or overwrite a text file inside the machine (parent folders must exist). Set append to add to the end instead.",
                            parameters: Schema.object([
                                "path": Schema.string("Absolute path inside the machine."),
                                "content": Schema.string("The full text to write."),
                                "append": Schema.boolean("Append instead of overwriting (default false)."),
                            ], required: ["path", "content"]))
        case .listDir:
            return ToolSpec(name: operation.rawValue,
                            description: "List a directory inside the machine (names, sizes, types). Needs the shell channel.",
                            parameters: Schema.object([
                                "path": Schema.string("Directory path (default: the home directory)."),
                                "all": Schema.boolean("Include hidden files (default false)."),
                            ]))
        }
    }

    /// Paths whose modification is treated as destructive.
    public static let protectedPrefixes = ["/etc/", "/boot/", "/bin/", "/sbin/", "/lib/", "/lib64/", "/usr/", "/System/",
                                           "/Library/", "/private/etc/", "/dev/", "/proc/", "/sys/"]

    public func risk(of call: ToolCall) -> ToolRisk {
        switch operation {
        case .readFile, .listDir:
            return .readOnly(operation.rawValue)
        case .writeFile:
            let path = ToolArguments(call).string(["path", "file", "filename"]) ?? ""
            if Self.protectedPrefixes.contains(where: { path.hasPrefix($0) }) {
                return .destructive("\(operation.rawValue):system", reason: "writes a system file (\(path))")
            }
            return .normal(operation.rawValue)
        }
    }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let surface = try ctx.requireSurface(for: operation.rawValue)
        let args = ToolArguments(call)
        switch operation {
        case .readFile:
            let path = try resolvePath(args)
            let data = try await surface.readFile(path: path)
            if let mime = ImageHeader.mimeType(of: data), mime == "image/png" || mime == "image/jpeg" {
                let image = ImageData(mime: mime, data: data).withDetectedSize()
                return ToolResult(callID: call.id, parts: [.text("\(path): \(mime), \(data.count) bytes"), .image(image)])
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return ToolResult(callID: call.id, text: "\(path) is a binary file (\(data.count) bytes); it cannot be shown as text.")
            }
            let limit = min(args.int("max_chars") ?? maxReadCharacters, maxReadCharacters)
            let t = TextLimits.truncate(text, max: max(limit, 100))
            return ToolResult(callID: call.id, text: t.text.isEmpty ? "(empty file)" : t.text)

        case .writeFile:
            let path = try resolvePath(args)
            guard let content = args.string(["content", "text", "data"]) else {
                throw ZError.invalidArgument("write_file needs a 'content' string.")
            }
            var data = Data(content.utf8)
            if args.bool("append") == true {
                let existing = (try? await surface.readFile(path: path)) ?? Data()
                data = existing + data
            }
            try await surface.writeFile(path: path, data: data)
            return ToolResult(callID: call.id, text: "Wrote \(data.count) bytes to \(path).")

        case .listDir:
            let path = (try? resolvePath(args)) ?? "~"
            let flags = args.bool("all") == true ? "-la" : "-l"
            let target = path == "~" ? "~" : TextLimits.shellQuote(path)
            let result: ShellResult
            do {
                result = try await surface.shell("ls \(flags) -- \(target)", timeout: 30)
            } catch ZError.unsupported {
                throw ZError.tool(name: operation.rawValue, message: "Listing folders needs the shell channel, which this machine does not have.")
            }
            if result.exitCode != 0 {
                let message = result.stderr.isEmpty ? result.stdout : result.stderr
                return ToolResult(callID: call.id, text: "ls failed (exit \(result.exitCode)): \(message)", isError: true)
            }
            let t = TextLimits.truncate(result.stdout, max: maxReadCharacters)
            return ToolResult(callID: call.id, text: t.text.isEmpty ? "(empty directory)" : t.text)
        }
    }

    private func resolvePath(_ args: ToolArguments) throws -> String {
        guard let p = args.string(["path", "file", "filename", "dir", "directory"])?.trimmingCharacters(in: .whitespaces), !p.isEmpty else {
            throw ZError.invalidArgument("\(operation.rawValue) needs a 'path'.")
        }
        return p
    }
}
