import AppKit
import SwiftUI
import ZCore

/// One activity row.
struct ActivityRow: View {
    var item: ActivityItem
    var showAgent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showAgent || isHeadline {
                HStack(spacing: 6) {
                    if showAgent { Text(item.agentName).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    Text(Format.time(item.timestamp)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isHeadline: Bool {
        switch item.kind {
        case .started, .toolCall, .approval, .finished, .error: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .started(let task):
            RowLabel(systemImage: "flag.fill", tint: .blue, title: "Task", text: task)
        case .status(let status):
            Text(status.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
        case .text(let text):
            Text(text)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        case .reasoning(let text):
            CollapsibleText(title: "Thinking", text: text, systemImage: "brain", italic: true)
        case .userMessage(let text):
            RowLabel(systemImage: "person.fill", tint: .accentColor, title: "You", text: text)
        case .toolCall(let call):
            ToolCallRow(call: call)
        case .toolResult(let result):
            ToolResultRow(result: result)
        case .screenshot(let image):
            ScreenshotThumbnail(image: image)
        case .approval(let request):
            ApprovalCard(request: request)
        case .note(let note):
            RowLabel(systemImage: "info.circle", tint: .secondary, title: nil, text: note)
                .font(.callout)
        case .usage(let usage):
            Text("Tokens: \(usage.inputTokens) in, \(usage.outputTokens) out"
                 + (usage.cachedInputTokens > 0 ? ", \(usage.cachedInputTokens) cached" : ""))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        case .finished(let outcome):
            RowLabel(systemImage: outcome.success ? "checkmark.seal.fill" : "xmark.octagon.fill",
                     tint: outcome.success ? .green : .orange,
                     title: outcome.success ? "Finished in \(outcome.steps) steps" : "Ended after \(outcome.steps) steps",
                     text: outcome.summary)
        case .error(let message):
            RowLabel(systemImage: "exclamationmark.triangle.fill", tint: .red, title: "Error", text: message)
        }
    }
}

private struct RowLabel: View {
    var systemImage: String
    var tint: Color
    var title: String?
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                if let title { Text(title).font(.callout.weight(.semibold)) }
                Text(text).textSelection(.enabled)
            }
        }
    }
}

/// Long text that starts collapsed.
private struct CollapsibleText: View {
    var title: String
    var text: String
    var systemImage: String
    var italic = false
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .italic(italic)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("\(title) · \(Format.clip(text.replacingOccurrences(of: "\n", with: " "), 70))", systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ToolCallRow: View {
    var call: ToolCall
    @State private var expanded = false

    var body: some View {
        let arguments = call.arguments.jsonString(pretty: true)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.purple)
                Text(call.name).font(.callout.monospaced().weight(.semibold))
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button(expanded ? "Hide" : "Arguments") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if expanded {
                Text(arguments)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.07)))
            }
        }
    }

    /// The most telling argument, inline ("ls -la", "click 120,300").
    private var summary: String {
        let a = call.arguments
        if let command = a["command"]?.stringValue { return command }
        if let action = a["action"]?.stringValue {
            var s = action
            if let x = a["x"]?.intValue, let y = a["y"]?.intValue { s += " \(x),\(y)" }
            if let coordinate = a["coordinate"]?.arrayValue, coordinate.count == 2,
               let x = coordinate[0].intValue, let y = coordinate[1].intValue { s += " \(x),\(y)" }
            if let text = a["text"]?.stringValue { s += " “\(Format.clip(text, 40))”" }
            return s
        }
        if let path = a["path"]?.stringValue { return path }
        if let query = a["query"]?.stringValue { return query }
        if let question = a["question"]?.stringValue { return question }
        if let summary = a["summary"]?.stringValue { return summary }
        return ""
    }
}

private struct ToolResultRow: View {
    var result: ToolResult
    @State private var expanded = false

    var body: some View {
        let text = result.text
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: result.isError ? "xmark.circle.fill" : "arrow.turn.down.right")
                .foregroundStyle(result.isError ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(expanded || text.count <= 400 ? (text.isEmpty ? "(no text)" : text) : Format.clip(text, 400))
                    .font(.caption.monospaced())
                    .foregroundStyle(result.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                if text.count > 400 {
                    Button(expanded ? "Show less" : "Show all (\(text.count) characters)") { expanded.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .padding(.leading, 4)
    }
}

/// A screenshot the agent looked at; click for a large preview.
struct ScreenshotThumbnail: View {
    var image: ImageData
    @State private var showing = false

    var body: some View {
        if let nsImage = NSImage(data: image.data) {
            Button {
                showing = true
            } label: {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 150, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Screenshot \(image.width ?? 0)×\(image.height ?? 0); click to enlarge")
            .popover(isPresented: $showing, arrowEdge: .leading) {
                ScreenshotPreview(image: nsImage, size: CGSize(width: image.width ?? 0, height: image.height ?? 0))
            }
        } else {
            Label("Screenshot (\(image.data.count) bytes, unreadable)", systemImage: "photo")
                .foregroundStyle(.secondary)
        }
    }
}

/// The QuickLook-style enlarged screenshot.
private struct ScreenshotPreview: View {
    var image: NSImage
    var size: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(minWidth: 480, idealWidth: 900, maxWidth: 1100, minHeight: 300, maxHeight: 760)
            HStack {
                Text("\(Int(size.width)) × \(Int(size.height)) px, as sent to the model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
        }
        .padding(12)
    }
}

/// Approve / Deny / Always allow.
private struct ApprovalCard: View {
    @Environment(AppModel.self) private var model
    var request: ApprovalRequest

    var body: some View {
        let session = model.agent
        let decision = session.resolvedApprovals[request.id]
        let pending = session.pendingApprovals.contains { $0.id == request.id }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("Approval needed: \(request.toolName)").font(.callout.weight(.semibold))
            }
            Text(request.summary).textSelection(.enabled)
            Text(request.arguments.jsonString(pretty: true))
                .font(.caption.monospaced())
                .lineLimit(8)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            if pending {
                HStack {
                    Button("Approve") { session.decide(request, .approve) }
                    Button("Deny", role: .destructive) { session.decide(request, .deny) }
                    Button("Always allow") { session.decide(request, .approveAlways) }
                        .help("Allow this kind of action for the rest of the session")
                }
            } else {
                Label(label(for: decision), systemImage: decision == .deny ? "xmark" : "checkmark")
                    .font(.caption)
                    .foregroundStyle(decision == .deny ? Color.red : Color.green)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(pending ? 0.14 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(pending ? 0.6 : 0.2)))
    }

    private func label(for decision: ApprovalDecision?) -> String {
        switch decision {
        case .approve: return "Approved"
        case .approveAlways: return "Approved (always for this session)"
        case .deny: return "Denied"
        case nil: return "No longer waiting"
        }
    }
}
