import Foundation
import ZCore

// ============================================================================================================
// PLACEHOLDER — shape only.
//
// TODO(research): the exact native computer-use tool formats — Anthropic `computer_2025xxxx` (action names,
// `coordinate` arrays, display size fields, beta headers), OpenAI Responses `computer_use_preview`
// (`computer_call` items, pending safety checks, `computer_call_output` screenshots) and Gemini `computer_use`
// (function names, normalised coordinate grid) — arrive from docs/research/local-models-and-agent-loops.md.
// Do not guess them here. Once that document lands, implement one `NativeComputerBridge` per vendor, unit-test it
// against recorded fixtures, and pass it to `AgentRunner(nativeBridge:)`.
//
// Until then the runner always uses the vendor-neutral `computer` function tool (`ComputerTool`), which every
// tool-calling model can drive.
// ============================================================================================================

/// Translates a provider's native computer-use tool to and from vendor-neutral `ComputerAction`s.
///
/// Flow: the runner advertises `toolSpec(modelDisplaySize:)` (a `ToolSpec` whose `native` is `kind`, so the
/// ZProviders client declares the vendor's native tool instead of a JSON function); when the model calls it,
/// `NativeComputerTool` asks the bridge to `translate` the call into actions in model coordinates, maps them to
/// surface coordinates (through `coordinateMapping(base:)`), runs them on the `ComputerSurface`, and returns a
/// screenshot. Vendors that need a special result shape can post-process with `finalize(_:for:)`.
public protocol NativeComputerBridge: Sendable {
    /// The native tool this bridge speaks; it is used only when `ModelCapabilities.nativeComputerUse == kind`.
    var kind: NativeToolKind { get }

    /// The tool to advertise. `modelDisplaySize` is the screenshot size the model sees.
    func toolSpec(modelDisplaySize: PixelSize) -> ToolSpec

    /// Native call → vendor-neutral actions in model coordinates.
    func translate(_ call: ToolCall) throws -> [ComputerAction]

    /// Coordinate hook: adjust the screenshot↔surface mapping for vendors whose coordinates are not screenshot
    /// pixels (for example a normalised grid). Default: unchanged.
    func coordinateMapping(base: CoordinateMapping) -> CoordinateMapping

    /// Result hook: reshape the tool result for the vendor (e.g. screenshot only). Default: unchanged.
    func finalize(_ result: ToolResult, for call: ToolCall) -> ToolResult
}

public extension NativeComputerBridge {
    func coordinateMapping(base: CoordinateMapping) -> CoordinateMapping { base }
    func finalize(_ result: ToolResult, for call: ToolCall) -> ToolResult { result }
}

/// Runs a native computer-use tool through a bridge and a `ComputerTool`.
public struct NativeComputerTool: Tool {
    public let bridge: any NativeComputerBridge
    public let computer: ComputerTool
    public let modelDisplaySize: PixelSize

    public init(bridge: any NativeComputerBridge, computer: ComputerTool, modelDisplaySize: PixelSize) {
        self.bridge = bridge; self.computer = computer; self.modelDisplaySize = modelDisplaySize
    }

    public var spec: ToolSpec { bridge.toolSpec(modelDisplaySize: modelDisplaySize) }

    public func risk(of call: ToolCall) -> ToolRisk {
        let actions = (try? bridge.translate(call)) ?? []
        if !actions.isEmpty, actions.allSatisfy(\.isReadOnly) { return .readOnly(ComputerTool.toolName) }
        return .normal(ComputerTool.toolName)
    }

    public func invoke(_ call: ToolCall, ctx: ToolContext) async throws -> ToolResult {
        let surface = try ctx.requireSurface(for: spec.name)
        let actions = try bridge.translate(call)
        let bridge = self.bridge
        let result = try await computer.perform(actions, callID: call.id, surface: surface,
                                                adjustMapping: { bridge.coordinateMapping(base: $0) })
        return bridge.finalize(result, for: call)
    }
}
