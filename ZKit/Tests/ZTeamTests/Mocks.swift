import Foundation
import XCTest
import ZCore
import ZAgent
@testable import ZTeam

/// A minimal PNG header (signature + IHDR) with the given size.
func fakePNG(width: Int, height: Int) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    bytes += [0x00, 0x00, 0x00, 0x0D]
    bytes += [0x49, 0x48, 0x44, 0x52]
    for v in [width, height] {
        bytes += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    bytes += [0x08, 0x06, 0x00, 0x00, 0x00]
    bytes += [0x00, 0x00, 0x00, 0x00]
    return Data(bytes)
}

/// Records every call. `inputDelay` makes each input call take a while (widens the window for interleaving).
actor MockSurface: ComputerSurface {
    enum Call: Equatable, Sendable {
        case screenshot
        case mouseMove(Int, Int)
        case click(Int, Int, MouseButton, Int)
        case mouseDown(Int, Int, MouseButton)
        case mouseUp(Int, Int, MouseButton)
        case drag(Int, Int, Int, Int)
        case scroll(Int, Int, Int, Int)
        case type(String)
        case keys(String)
        case keyDown(String)
        case keyUp(String)
        case shell(String)
        case readFile(String)
        case writeFile(String, Data)

        var isScreenshot: Bool { self == .screenshot }
    }

    private(set) var calls: [Call] = []
    private var files: [String: Data] = [:]
    private let size: PixelSize
    private let inputDelay: UInt64

    init(size: PixelSize = PixelSize(width: 1024, height: 768), inputDelayMilliseconds: UInt64 = 0) {
        self.size = size
        self.inputDelay = inputDelayMilliseconds * 1_000_000
    }

    var info: SurfaceInfo {
        SurfaceInfo(name: "Mock VM", osFamily: "linux", architecture: "arm64", shellAvailable: true, hasDesktop: true)
    }
    var displaySize: PixelSize { size }

    var inputCalls: [Call] { calls.filter { !$0.isScreenshot } }
    var shellCommands: [String] { calls.compactMap { if case .shell(let c) = $0 { return c } else { return nil } } }
    var typedTexts: [String] { calls.compactMap { if case .type(let t) = $0 { return t } else { return nil } } }

    private func record(_ call: Call) async {
        calls.append(call)
        if inputDelay > 0 { try? await Task.sleep(nanoseconds: inputDelay) }
    }

    func screenshot() async throws -> ImageData {
        calls.append(.screenshot)
        return ImageData(mime: "image/png", data: fakePNG(width: size.width, height: size.height))
    }
    func mouseMove(x: Int, y: Int) async throws { await record(.mouseMove(x, y)) }
    func click(x: Int, y: Int, button: MouseButton, count: Int) async throws { await record(.click(x, y, button, count)) }
    func mouseDown(x: Int, y: Int, button: MouseButton) async throws { await record(.mouseDown(x, y, button)) }
    func mouseUp(x: Int, y: Int, button: MouseButton) async throws { await record(.mouseUp(x, y, button)) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws { await record(.drag(fromX, fromY, toX, toY)) }
    func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws { await record(.scroll(x, y, dx, dy)) }
    func typeText(_ text: String) async throws { await record(.type(text)) }
    func pressKeys(_ combo: String) async throws { await record(.keys(combo)) }
    func keyDown(_ key: String) async throws { await record(.keyDown(key)) }
    func keyUp(_ key: String) async throws { await record(.keyUp(key)) }

    func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        await record(.shell(command))
        return ShellResult(stdout: "ran: \(command)")
    }

    func readFile(path: String) async throws -> Data {
        await record(.readFile(path))
        guard let d = files[path] else { throw ZError.notFound(path) }
        return d
    }

    func writeFile(path: String, data: Data) async throws {
        await record(.writeFile(path, data))
        files[path] = data
    }
}

/// An LLM whose replies come from a handler that sees each request (index, messages, tools).
/// The handler may suspend (e.g. to simulate a slow model); cancelling the stream cancels it.
final class ScriptedClient: LLMClient, @unchecked Sendable {
    struct Request: Sendable {
        let index: Int
        let messages: [ChatMessage]
        let tools: [ToolSpec]

        /// The last message (the newest user prompt or tool results).
        var last: ChatMessage? { messages.last }
        /// Text of the newest user message.
        var lastUserText: String { messages.last { $0.role == .user }?.text ?? "" }
        /// True when this request starts a new run (the newest message is the task prompt).
        var isNewRun: Bool { messages.last?.role == .user }
        /// Text of the tool results in the newest message.
        var lastToolResultText: String { messages.last?.toolResults.map(\.text).joined(separator: "\n") ?? "" }
    }

    let model: ModelRef
    let capabilities: ModelCapabilities
    private let lock = NSLock()
    private var recorded: [Request] = []
    private let handler: @Sendable (Request) async -> [StreamEvent]

    init(name: String = "scripted", capabilities: ModelCapabilities = ModelCapabilities(vision: true, tools: true),
         handler: @escaping @Sendable (Request) async -> [StreamEvent]) {
        self.model = ModelRef(provider: "mock", model: name)
        self.capabilities = capabilities
        self.handler = handler
    }

    /// Plays a fixed script, one entry per request; then answers with plain text (which ends a run).
    static func script(_ steps: [[StreamEvent]], name: String = "scripted") -> ScriptedClient {
        let queue = ScriptQueue(steps)
        return ScriptedClient(name: name) { _ in queue.next() }
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private func record(_ messages: [ChatMessage], _ tools: [ToolSpec]) -> Request {
        lock.lock(); defer { lock.unlock() }
        let r = Request(index: recorded.count, messages: messages, tools: tools)
        recorded.append(r)
        return r
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        let request = record(messages, tools)
        let handler = self.handler
        return AsyncThrowingStream { continuation in
            let task = Task {
                let events = await handler(request)
                for e in events { continuation.yield(e) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func listModels() async throws -> [ModelInfo] { [] }
}

final class ScriptQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [[StreamEvent]]
    init(_ steps: [[StreamEvent]]) { self.steps = steps }
    func next() -> [StreamEvent] {
        lock.lock(); defer { lock.unlock() }
        if steps.isEmpty { return [.textDelta("(script exhausted)"), .finished(.stop)] }
        return steps.removeFirst()
    }
}

// MARK: - Script helpers

/// One tool call as a full model turn (with a little usage).
func toolTurn(_ id: String, _ name: String, _ arguments: JSONValue = [:]) -> [StreamEvent] {
    [.toolCall(ToolCall(id: id, name: name, arguments: arguments)),
     .usage(Usage(inputTokens: 10, outputTokens: 2)),
     .finished(.toolCalls)]
}

/// `task_complete` as a full model turn.
func completeTurn(_ id: String, _ summary: String, success: Bool = true) -> [StreamEvent] {
    toolTurn(id, "task_complete", ["summary": .string(summary), "success": .bool(success)])
}

/// The task number in a worker prompt ("Your task — Task #2: ...").
func taskNumber(in prompt: String) -> String {
    guard let range = prompt.range(of: "Task #") else { return "?" }
    return String(prompt[range.upperBound...].prefix { $0.isNumber })
}

func teamMember(_ id: String, _ role: TeamRole, instructions: String = "") -> TeamMember {
    TeamMember(id: id, name: id.prefix(1).uppercased() + id.dropFirst(), role: role,
               model: ModelRef(provider: "mock", model: id), instructions: instructions)
}

func quietPolicy(_ mode: ApprovalMode = .never) -> AgentPolicy {
    AgentPolicy(maxSteps: 12, approvalMode: mode, actionSettleDelay: 0, initialScreenshot: false)
}

/// A client factory over fixed clients by member id.
func factory(_ clients: [String: ScriptedClient]) -> TeamRunner.ClientFactory {
    { member in
        guard let c = clients[member.id] else { throw ZError.notFound("client for \(member.id)") }
        return c
    }
}

/// Runs the team; stops it (and fails the test) when it takes longer than `seconds`.
func runTeam(_ team: TeamRunner, seconds: Double = 15, file: StaticString = #filePath, line: UInt = #line) async -> TeamOutcome {
    let flag = TimeoutFlag()
    let watchdog = Task {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if Task.isCancelled { return }
        await flag.set()
        await team.stop()
    }
    let outcome = await team.run()
    watchdog.cancel()
    if await flag.fired { XCTFail("The team did not finish within \(seconds) s", file: file, line: line) }
    return outcome
}

actor TimeoutFlag {
    private(set) var fired = false
    func set() { fired = true }
}

/// Polls `condition` until it is true or the timeout passes.
func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
               _ condition: @Sendable () async -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition", file: file, line: line)
}

/// Collects the owner sequence of a call log: consecutive calls with the same owner collapse into one entry.
func runs<T: Equatable>(_ owners: [T]) -> [T] {
    var out: [T] = []
    for o in owners where out.last != o { out.append(o) }
    return out
}
