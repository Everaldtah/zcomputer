import Foundation
import XCTest
import ZCore
@testable import ZAgent

/// A minimal PNG header (signature + IHDR) with the given size. Enough for header parsing; not decodable.
func fakePNG(width: Int, height: Int) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    bytes += [0x00, 0x00, 0x00, 0x0D]            // IHDR length
    bytes += [0x49, 0x48, 0x44, 0x52]            // "IHDR"
    for v in [width, height] {
        bytes += [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    bytes += [0x08, 0x06, 0x00, 0x00, 0x00]      // depth, colour type, compression, filter, interlace
    bytes += [0x00, 0x00, 0x00, 0x00]            // CRC (not checked)
    return Data(bytes)
}

/// Records every call; screenshots are fake PNG blobs of the display size.
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
        case shell(String)
        case readFile(String)
        case writeFile(String, Data)
    }

    private(set) var calls: [Call] = []
    private var files: [String: Data] = [:]
    private let size: PixelSize
    private let shellAvailable: Bool
    private let shellHandler: @Sendable (String) -> ShellResult

    init(size: PixelSize = PixelSize(width: 1024, height: 768), shellAvailable: Bool = true,
         shellHandler: @escaping @Sendable (String) -> ShellResult = { ShellResult(stdout: "ran: \($0)") }) {
        self.size = size
        self.shellAvailable = shellAvailable
        self.shellHandler = shellHandler
    }

    var info: SurfaceInfo {
        SurfaceInfo(name: "Mock VM", osFamily: "linux", architecture: "arm64", shellAvailable: shellAvailable, hasDesktop: true)
    }
    var displaySize: PixelSize { size }

    var shellCommands: [String] { calls.compactMap { if case .shell(let c) = $0 { return c } else { return nil } } }

    func setFile(_ path: String, _ data: Data) { files[path] = data }
    func file(_ path: String) -> Data? { files[path] }

    func screenshot() async throws -> ImageData {
        calls.append(.screenshot)
        return ImageData(mime: "image/png", data: fakePNG(width: size.width, height: size.height))
    }
    func mouseMove(x: Int, y: Int) async throws { calls.append(.mouseMove(x, y)) }
    func click(x: Int, y: Int, button: MouseButton, count: Int) async throws { calls.append(.click(x, y, button, count)) }
    func mouseDown(x: Int, y: Int, button: MouseButton) async throws { calls.append(.mouseDown(x, y, button)) }
    func mouseUp(x: Int, y: Int, button: MouseButton) async throws { calls.append(.mouseUp(x, y, button)) }
    func drag(fromX: Int, fromY: Int, toX: Int, toY: Int) async throws { calls.append(.drag(fromX, fromY, toX, toY)) }
    func scroll(x: Int, y: Int, dx: Int, dy: Int) async throws { calls.append(.scroll(x, y, dx, dy)) }
    func typeText(_ text: String) async throws { calls.append(.type(text)) }
    func pressKeys(_ combo: String) async throws { calls.append(.keys(combo)) }

    func shell(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        calls.append(.shell(command))
        guard shellAvailable else { throw ZError.unsupported("shell") }
        return shellHandler(command)
    }

    func readFile(path: String) async throws -> Data {
        calls.append(.readFile(path))
        guard let d = files[path] else { throw ZError.notFound(path) }
        return d
    }

    func writeFile(path: String, data: Data) async throws {
        calls.append(.writeFile(path, data))
        files[path] = data
    }
}

/// Scripted LLM: each `stream` call plays the next array of events and records the request.
final class MockLLMClient: LLMClient, @unchecked Sendable {
    let model = ModelRef(provider: "mock", model: "scripted")
    let capabilities: ModelCapabilities

    private let lock = NSLock()
    private var script: [[StreamEvent]]
    private var recorded: [[ChatMessage]] = []
    private var recordedTools: [[ToolSpec]] = []

    init(capabilities: ModelCapabilities = ModelCapabilities(vision: true, tools: true), script: [[StreamEvent]]) {
        self.capabilities = capabilities
        self.script = script
    }

    var requests: [[ChatMessage]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var requestTools: [[ToolSpec]] {
        lock.lock(); defer { lock.unlock() }
        return recordedTools
    }

    var requestCount: Int { requests.count }

    private func next(_ messages: [ChatMessage], _ tools: [ToolSpec]) -> [StreamEvent] {
        lock.lock(); defer { lock.unlock() }
        recorded.append(messages)
        recordedTools.append(tools)
        if script.isEmpty { return [.textDelta("(script exhausted)"), .finished(.stop)] }
        return script.removeFirst()
    }

    func stream(messages: [ChatMessage], tools: [ToolSpec], options: GenerationOptions) -> AsyncThrowingStream<StreamEvent, Error> {
        let events = next(messages, tools)
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            continuation.finish()
        }
    }

    func listModels() async throws -> [ModelInfo] { [] }
}

/// A test tool that runs a hook (e.g. talks to the runner while the loop is suspended inside a tool).
struct HookTool: Tool {
    let name: String
    let hook: @Sendable () async -> Void

    init(name: String = "hook", hook: @escaping @Sendable () async -> Void) { self.name = name; self.hook = hook }

    var spec: ToolSpec { ToolSpec(name: name, description: "Test hook.") }
    func risk(of call: ToolCall) -> ToolRisk { .readOnly(name) }
    func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        await hook()
        return ToolResult(callID: call.id, text: "hook ran")
    }
}

/// Lets a hook reach a runner created after the hook.
actor RunnerRef {
    private(set) var runner: AgentRunner?
    func set(_ r: AgentRunner) { runner = r }
}

/// Simple in-memory MemoryStore for tool tests.
actor InMemoryMemoryStore: MemoryStore {
    private(set) var items: [MemoryItem] = []

    func save(_ item: MemoryItem) async throws {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }
    func get(id: UUID) async throws -> MemoryItem? { items.first { $0.id == id } }
    func delete(id: UUID) async throws { items.removeAll { $0.id == id } }
    func list(kind: MemoryKind?, limit: Int, offset: Int) async throws -> [MemoryItem] {
        Array(items.filter { kind == nil || $0.kind == kind }.dropFirst(offset).prefix(limit))
    }
    func search(_ query: String, kinds: [MemoryKind], limit: Int) async throws -> [MemoryHit] {
        let q = query.lowercased()
        return items
            .filter { kinds.isEmpty || kinds.contains($0.kind) }
            .filter { $0.text.lowercased().contains(q) || $0.title.lowercased().contains(q) }
            .prefix(limit)
            .map { MemoryHit(item: $0, score: 1) }
    }
    func importDocument(title: String, text: String, source: String, tags: [String]) async throws -> MemoryItem {
        let item = MemoryItem(kind: .document, title: title, text: text, tags: tags, source: source)
        items.append(item)
        return item
    }
    func count(kind: MemoryKind?) async throws -> Int { items.filter { kind == nil || $0.kind == kind }.count }
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

/// A short label per event, for comparing sequences.
func label(_ event: AgentEvent) -> String {
    switch event {
    case .started: return "started"
    case .status(let s): return "status:\(s.rawValue)"
    case .textDelta: return "textDelta"
    case .reasoningDelta: return "reasoningDelta"
    case .message(let m): return "message:\(m.role.rawValue)"
    case .toolCall(let c): return "toolCall:\(c.name)"
    case .toolResult(let r): return "toolResult\(r.isError ? ":error" : "")"
    case .screenshot: return "screenshot"
    case .approvalRequested: return "approvalRequested"
    case .approvalResolved(_, let d): return "approvalResolved:\(d.rawValue)"
    case .usage: return "usage"
    case .note: return "note"
    case .finished: return "finished"
    case .error: return "error"
    }
}

func testEmitter(_ bus: EventBus = EventBus()) -> AgentEmitter {
    AgentEmitter(agentID: "test", agentName: "Test", sink: bus)
}

func testContext(surface: (any ComputerSurface)? = nil, memory: (any MemoryStore)? = nil, bus: EventBus = EventBus(),
                 gate: ApprovalGate? = nil, userInput: UserInputChannel? = nil, control: RunControl? = nil) -> ToolContext {
    let em = testEmitter(bus)
    return ToolContext(agentID: "test", agentName: "Test", surface: surface, memory: memory, emitter: em,
                       approval: gate ?? ApprovalGate(mode: .never, emitter: em), userInput: userInput, control: control)
}
