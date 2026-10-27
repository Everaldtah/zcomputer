import Foundation
import ZCore

/// `shell(command, timeout)` — runs a command inside the machine through `ComputerSurface.shell`.
/// Destructive commands (see `DestructiveCommandDetector`) are marked for approval.
public struct ShellTool: Tool {
    public static let toolName = "shell"
    public static let defaultTimeout: TimeInterval = 60
    public static let maxTimeout: TimeInterval = 600

    /// Characters of stdout and of stderr kept in the result (head + tail), 16 kB each per the brief.
    public var maxOutputCharacters: Int

    public init(maxOutputCharacters: Int = 16_000) { self.maxOutputCharacters = maxOutputCharacters }

    /// Brief B1.2 schema.
    static let schemaJSON = #"""
    {"type": "object",
     "properties": {"command": {"type": "string", "description": "The bash command line."},
                    "timeout_seconds": {"type": "integer", "minimum": 1, "maximum": 600, "description": "Default 60."}},
     "required": ["command"], "additionalProperties": false}
    """#

    public var spec: ToolSpec {
        let parameters = (try? JSONValue.parse(Self.schemaJSON))
            ?? Schema.object(["command": Schema.string("The bash command line.")], required: ["command"])
        return ToolSpec(
            name: Self.toolName,
            description: "Run one bash command inside the virtual machine through the guest agent (bash -lc). Returns exit_code, stdout, stderr (truncated to 16 kB each). Destructive commands may require user approval.",
            parameters: parameters)
    }

    public func risk(of call: ToolCall) -> ToolRisk {
        let command = ToolArguments(call).string(["command", "cmd"]) ?? ""
        if let match = DestructiveCommandDetector.detect(command) {
            return .destructive("\(Self.toolName):\(match.rule)", reason: match.reason)
        }
        return .normal(Self.toolName)
    }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let args = ToolArguments(call)
        guard let command = args.string(["command", "cmd"]), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ZError.invalidArgument("shell needs a non-empty 'command'.")
        }
        let surface = try ctx.requireSurface(for: Self.toolName)
        let timeout = min(max(args.double("timeout_seconds") ?? args.double("timeout") ?? Self.defaultTimeout, 1), Self.maxTimeout)
        let result: ShellResult
        do {
            result = try await surface.shell(command, timeout: timeout)
        } catch ZError.unsupported(let what) {
            throw ZError.tool(name: Self.toolName,
                              message: "No shell channel on this machine (\(what)). Use the computer tool (e.g. open a terminal window) instead.")
        }
        return ToolResult(callID: call.id, text: format(result), isError: result.exitCode != 0)
    }

    /// `{"exit_code":0,"stdout":"…","stderr":"…","truncated":false,"duration_s":0.4}` (brief B1.2), so every model
    /// parses it the same way.
    func format(_ r: ShellResult) -> String {
        let stdout = TextLimits.truncate(r.stdout, max: maxOutputCharacters)
        let stderr = TextLimits.truncate(r.stderr, max: maxOutputCharacters)
        let result: JSONValue = .object([
            "exit_code": .number(Double(r.exitCode)),
            "stdout": .string(stdout.text),
            "stderr": .string(stderr.text),
            "truncated": .bool(r.truncated || stdout.truncated || stderr.truncated),
            "duration_s": .number((r.durationSeconds * 10).rounded() / 10),
        ])
        return result.jsonString()
    }
}

/// Recognises commands that can destroy data or take the machine down. Conservative on purpose:
/// a false positive costs one approval click, a false negative can cost the machine.
public enum DestructiveCommandDetector {
    public struct Match: Hashable, Sendable {
        /// Short stable rule id, used as the approval kind ("rm -r", "mkfs", "curl | sh" ...).
        public var rule: String
        public var reason: String
        public init(rule: String, reason: String) { self.rule = rule; self.reason = reason }
    }

    /// The rules, for display in settings / docs.
    public static let rules: [Match] = [
        Match(rule: "rm -r", reason: "recursive delete"),
        Match(rule: "rm /", reason: "deletes everything in a folder, or a system / home path"),
        Match(rule: "mkfs", reason: "formats a filesystem"),
        Match(rule: "dd", reason: "raw write with dd"),
        Match(rule: "disk", reason: "partitions or wipes a disk"),
        Match(rule: "power", reason: "shuts down or reboots the machine"),
        Match(rule: "fork bomb", reason: "fork bomb"),
        Match(rule: "curl | sh", reason: "runs a script downloaded from the internet"),
        Match(rule: "chmod 777", reason: "makes files world-writable"),
        Match(rule: "chown /", reason: "changes ownership recursively on system paths"),
        Match(rule: "accounts", reason: "changes user accounts or passwords"),
        Match(rule: "device write", reason: "writes directly to a block device"),
        Match(rule: "system file", reason: "overwrites a system configuration file"),
        Match(rule: "kill all", reason: "kills every process"),
        Match(rule: "crontab -r", reason: "removes all cron jobs"),
        Match(rule: "git destructive", reason: "discards git history or local changes"),
        Match(rule: "find -delete", reason: "bulk delete with find"),
        Match(rule: "mv /dev/null", reason: "moves files into /dev/null"),
    ]

    private static func rule(_ id: String) -> Match {
        rules.first { $0.rule == id } ?? Match(rule: id, reason: id)
    }

    /// Returns the first destructive rule the command matches, or nil.
    public static func detect(_ command: String) -> Match? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        if let m = detectByPattern(cmd) { return m }
        for segment in segments(of: cmd) {
            if let m = detect(tokens: segment, depth: 0) { return m }
        }
        return nil
    }

    // MARK: Whole-command patterns

    private static let patterns: [(rule: String, regex: String)] = [
        ("fork bomb", #":\s*\(\s*\)\s*\{[^}]*:\s*\|\s*:"#),
        ("fork bomb", #"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*\{[^}]*\b\1\s*\|\s*\1\b"#),
        ("curl | sh", #"\b(curl|wget|fetch)\b[^|;&\n]*\|\s*(sudo\s+(-\S+\s+)*)?(env\s+)?(sh|bash|zsh|dash|ksh|fish)\b"#),
        ("curl | sh", #"\b(sh|bash|zsh|dash|eval|source)\b[^;&\n]*(\$\(|`|<\()\s*(curl|wget)\b"#),
        ("device write", #">\s*/dev/(sd[a-z]|hd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]|mmcblk[0-9]|disk[0-9]|rdisk[0-9])"#),
        ("system file", #">\s*/(etc|boot)/"#),
    ]

    private static func detectByPattern(_ cmd: String) -> Match? {
        let range = NSRange(cmd.startIndex..<cmd.endIndex, in: cmd)
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p.regex, options: [.caseInsensitive]) else { continue }
            if re.firstMatch(in: cmd, options: [], range: range) != nil { return rule(p.rule) }
        }
        return nil
    }

    // MARK: Tokenised checks

    /// Splits a command line into simple-command token lists at ; && || | & newlines, subshells and backticks.
    /// Quotes are dropped (deliberately: `bash -c "rm -rf x"` must still be seen).
    static func segments(of cmd: String) -> [[String]] {
        var segs: [[String]] = []
        var current = ""
        let separators: Set<Character> = [";", "|", "&", "\n", "\r", "(", ")", "`", "{", "}"]
        for ch in cmd {
            if separators.contains(ch) {
                segs.append(tokens(current)); current = ""
            } else if ch == "\"" || ch == "'" {
                continue
            } else if ch == "$" {
                current.append(" ")
            } else {
                current.append(ch)
            }
        }
        segs.append(tokens(current))
        return segs.filter { !$0.isEmpty }
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    private static let wrappers: Set<String> = ["sudo", "doas", "nohup", "nice", "time", "command", "exec", "xargs",
                                                "timeout", "stdbuf", "ionice", "env", "builtin", "chroot", "watch",
                                                "su", "runuser", "unbuffer", "caffeinate"]
    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "ash"]

    /// Wrapper options that take a value (`sudo -u admin`, `nice -n 5`, `xargs -I {}` ...).
    private static let wrapperOptionsWithValue: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U"],
        "doas": ["-u", "-C"],
        "nice": ["-n"],
        "ionice": ["-c", "-n", "-p"],
        "timeout": ["-s", "-k", "--signal", "--kill-after"],
        "xargs": ["-I", "-n", "-P", "-L", "-d", "-E", "-s", "-a"],
        "env": ["-u", "-C", "-S"],
        "stdbuf": ["-i", "-o", "-e"],
        "watch": ["-n"],
        "runuser": ["-u", "-g", "-s"],
        "su": ["-s", "-g", "-G"],
    ]

    private static func isAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        let name = token[..<eq]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber } && !(name.first?.isNumber ?? true)
    }

    private static func isDurationOrNumber(_ token: String) -> Bool {
        if Double(token) != nil { return true }
        guard let last = token.last, "smhd".contains(last) else { return false }
        return Double(token.dropLast()) != nil
    }

    /// Removes leading wrappers (sudo, env A=b, timeout 10, nice -n 5, xargs -0 ...) and variable assignments.
    private static func stripWrappers(_ tokens: [String]) -> [String] {
        var t = tokens
        while let first = t.first {
            if isAssignment(first) { t.removeFirst(); continue }
            let name = basename(first)
            guard wrappers.contains(name) else { break }
            t.removeFirst()
            if name == "su" || name == "runuser", let c = t.firstIndex(of: "-c") {
                // su [user] -c "command" [user]: the command follows -c.
                t = Array(t[(c + 1)...])
                continue
            }
            while let next = t.first {
                if next.hasPrefix("-") {
                    t.removeFirst()
                    if wrapperOptionsWithValue[name]?.contains(next) == true, !t.isEmpty { t.removeFirst() }
                } else if isAssignment(next) || ((name == "timeout" || name == "watch") && isDurationOrNumber(next)) {
                    t.removeFirst()
                } else {
                    break
                }
            }
            if name == "chroot", !t.isEmpty { t.removeFirst() }   // chroot NEWROOT command
        }
        return t
    }

    private static func detect(tokens raw: [String], depth: Int) -> Match? {
        guard depth < 4 else { return nil }
        let t = stripWrappers(raw)
        guard let first = t.first else { return nil }
        let prog = basename(first).lowercased()
        let args = Array(t.dropFirst())
        let flags = args.filter { $0.hasPrefix("-") }
        let operands = args.filter { !$0.hasPrefix("-") }
        let shortFlags = Set(flags.filter { !$0.hasPrefix("--") }.flatMap { $0.dropFirst() })

        // Nested shells: bash -c "..." / bash -lc "..." / eval ...
        if shells.contains(prog),
           let c = args.firstIndex(where: { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c")) }) {
            if let m = detect(tokens: Array(args[(c + 1)...]), depth: depth + 1) { return m }
        }
        if prog == "eval" { return detect(tokens: args, depth: depth + 1) }

        switch prog {
        case "rm":
            if shortFlags.contains("r") || shortFlags.contains("R") || flags.contains("--recursive") { return rule("rm -r") }
            if flags.contains("--no-preserve-root") || operands.contains(where: isCriticalPath) { return rule("rm /") }
        case "unlink":
            if operands.contains(where: isCriticalPath) { return rule("rm /") }
        case _ where prog.hasPrefix("mkfs") || prog == "mke2fs" || prog == "mkswap" || prog == "newfs" || prog.hasPrefix("newfs_"):
            return rule("mkfs")
        case "dd":
            if args.contains(where: { $0.lowercased().hasPrefix("of=") }) { return rule("dd") }
        case "fdisk", "sfdisk", "cfdisk", "parted", "gdisk", "sgdisk", "wipefs", "shred", "blkdiscard", "zpool", "pvremove", "vgremove", "lvremove":
            return rule("disk")
        case "diskutil":
            if let verb = operands.first?.lowercased(),
               verb.hasPrefix("erase") || verb.hasPrefix("partition") || verb.hasPrefix("zero") || verb.hasPrefix("secureerase") || verb == "reformat" {
                return rule("disk")
            }
        case "shutdown", "reboot", "halt", "poweroff", "kexec":
            return rule("power")
        case "init", "telinit":
            if operands.contains("0") || operands.contains("6") { return rule("power") }
        case "systemctl", "loginctl":
            if operands.contains(where: { ["poweroff", "reboot", "halt", "kexec", "suspend", "hibernate", "kill-session", "terminate-session"].contains($0.lowercased()) }) {
                return rule("power")
            }
        case "chmod":
            let recursive = shortFlags.contains("R") || flags.contains("--recursive")
            let worldWritable = operands.contains { ["777", "0777", "a+rwx", "ugo+rwx", "o+w", "a+w", "666", "0666"].contains($0.lowercased()) }
            if worldWritable && (recursive || operands.contains(where: isCriticalPath)) { return rule("chmod 777") }
            if recursive && operands.contains(where: isCriticalPath) { return rule("chmod 777") }
        case "chown", "chgrp":
            let recursive = shortFlags.contains("R") || flags.contains("--recursive")
            if recursive && operands.contains(where: isCriticalPath) { return rule("chown /") }
        case "passwd", "chpasswd", "usermod", "userdel", "deluser", "groupdel", "delgroup", "dscl", "sysadminctl":
            return rule("accounts")
        case "kill":
            if args.last == "-1" { return rule("kill all") }
        case "killall5":
            return rule("kill all")
        case "crontab":
            if shortFlags.contains("r") { return rule("crontab -r") }
        case "git":
            if let m = detectGit(args) { return m }
        case "find":
            if args.contains("-delete") { return rule("find -delete") }
            if let e = args.firstIndex(where: { $0 == "-exec" || $0 == "-execdir" || $0 == "-ok" }), e + 1 < args.count,
               ["rm", "shred", "unlink"].contains(basename(args[e + 1])) {
                return rule("find -delete")
            }
        case "mv":
            if operands.last == "/dev/null" { return rule("mv /dev/null") }
        case "truncate":
            if operands.contains(where: isCriticalPath) { return rule("system file") }
        default:
            break
        }
        return nil
    }

    private static func detectGit(_ args: [String]) -> Match? {
        guard let sub = args.first(where: { !$0.hasPrefix("-") }) else { return nil }
        let rest = args.drop(while: { $0 != sub }).dropFirst()
        let flags = rest.filter { $0.hasPrefix("-") }
        let short = Set(flags.filter { !$0.hasPrefix("--") }.flatMap { $0.dropFirst() })
        switch sub {
        case "push":
            if flags.contains(where: { $0 == "--force" || $0.hasPrefix("--force-with-lease") || $0 == "--mirror" || $0 == "--delete" }) || short.contains("f") || short.contains("d") {
                return rule("git destructive")
            }
        case "reset":
            if flags.contains("--hard") { return rule("git destructive") }
        case "clean":
            if short.contains("f") || flags.contains("--force") { return rule("git destructive") }
        case "checkout", "restore":
            if rest.contains(".") { return rule("git destructive") }
        case "branch":
            if short.contains("D") { return rule("git destructive") }
        case "filter-branch", "filter-repo":
            return rule("git destructive")
        default:
            break
        }
        return nil
    }

    /// `/`, `/*`, `~`, `$HOME`, `*`, `.`, `..` and top-level system directories.
    static func isCriticalPath(_ raw: String) -> Bool {
        var p = raw.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("$") { p.removeFirst() }       // "$" was replaced by a space earlier; be tolerant
        if p.isEmpty { return false }
        let exact: Set<String> = ["/", "/*", "~", "~/", "~/*", "*", ".", "..", "./*", "HOME", "{HOME}", "HOME/", "HOME/*"]
        if exact.contains(p) { return true }
        var trimmed = p
        while trimmed.count > 1, trimmed.hasSuffix("/") || trimmed.hasSuffix("*") { trimmed.removeLast() }
        let top: Set<String> = ["/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/opt", "/proc", "/root", "/sbin",
                                "/sys", "/usr", "/var", "/System", "/Library", "/Users", "/Applications", "/private"]
        return top.contains(trimmed)
    }

    private static func basename(_ s: String) -> String {
        guard let slash = s.lastIndex(of: "/") else { return s }
        let rest = s[s.index(after: slash)...]
        return rest.isEmpty ? s : String(rest)
    }
}
