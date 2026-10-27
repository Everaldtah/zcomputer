import Foundation
import ZCore

/// How the agent declares and calls tools.
public enum ToolCallMode: String, Codable, Sendable, Hashable, CaseIterable {
    /// Native tool calling when `ModelCapabilities.tools` is true, text blocks otherwise.
    case auto
    /// Always native tool calling.
    case native
    /// Always fenced-JSON text blocks (`TextToolCallParser`).
    case text
}

/// Knobs for one agent's run.
public struct AgentPolicy: Hashable, Codable, Sendable {
    /// Model calls before the run gives up.
    public var maxSteps: Int
    public var approvalMode: ApprovalMode
    /// Longest side of screenshots sent to the model.
    public var screenshotMaxEdge: Int
    /// Pause between steps (seconds), e.g. to watch the agent or respect rate limits.
    public var stepDelay: TimeInterval
    /// Estimated transcript tokens before older turns are summarised (capped at 75% of the model's context window).
    public var tokenBudget: Int
    /// Use the provider's native computer-use tool when the model has one and a `NativeComputerBridge` is supplied.
    public var useNativeComputerUse: Bool
    /// Screenshots kept as images in the transcript (older ones become "[screenshot omitted]").
    public var keepScreenshots: Int
    /// Wait after an input action before the follow-up screenshot (seconds).
    public var actionSettleDelay: TimeInterval
    /// Attach a screenshot to the task message when a machine with a desktop is attached.
    public var initialScreenshot: Bool
    public var toolCallMode: ToolCallMode
    /// Options passed to every model call.
    public var generation: GenerationOptions

    public init(maxSteps: Int = 50,
                approvalMode: ApprovalMode = .destructiveOnly,
                screenshotMaxEdge: Int = ScreenshotScaler.defaultMaxLongEdge,
                stepDelay: TimeInterval = 0,
                tokenBudget: Int = 100_000,
                useNativeComputerUse: Bool = true,
                keepScreenshots: Int = 3,
                actionSettleDelay: TimeInterval = 0.5,
                initialScreenshot: Bool = true,
                toolCallMode: ToolCallMode = .auto,
                generation: GenerationOptions = .standard) {
        self.maxSteps = maxSteps
        self.approvalMode = approvalMode
        self.screenshotMaxEdge = screenshotMaxEdge
        self.stepDelay = stepDelay
        self.tokenBudget = tokenBudget
        self.useNativeComputerUse = useNativeComputerUse
        self.keepScreenshots = keepScreenshots
        self.actionSettleDelay = actionSettleDelay
        self.initialScreenshot = initialScreenshot
        self.toolCallMode = toolCallMode
        self.generation = generation
    }

    public static let standard = AgentPolicy()
}
