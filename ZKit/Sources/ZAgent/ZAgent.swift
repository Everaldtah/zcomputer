import Foundation
import ZCore

/// ZAgent: the agent loop, the built-in tools, approvals and the computer-use plumbing.
///
/// Entry points:
/// * `AgentRunner` — one agent working on one machine (`ComputerSurface`) with one model (`LLMClient`).
/// * `Tool` / `ToolRegistry` / `ToolContext` — the tool contract; built-ins are `ComputerTool`, `ShellTool`,
///   `FileTool`, `MemoryTool` and `TaskTool`.
/// * `ApprovalGate` — human-in-the-loop approvals (never / destructiveOnly / always, "always allow" per kind).
/// * `ScreenshotScaler`, `TextToolCallParser`, `ContextManager` — the pure helpers the loop is built from.
///
/// ZAgent only depends on the ZCore contracts; ZProviders / ZMemory plug in through `LLMClient`,
/// `MemoryStore`, `EpisodeSink` and `MemoryContextProvider`.
public enum ZAgentModule {
    public static let name = "ZAgent"
}
