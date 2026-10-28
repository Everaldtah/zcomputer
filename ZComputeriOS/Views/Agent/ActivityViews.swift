import SwiftUI
import UIKit
import ZCore

/// The "what is the agent doing" timeline: every agent's events (thinking, text, tool calls with arguments, results,
/// screenshots, approvals) with a per-agent filter.
struct ActivityPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var session = model.agent
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !session.pendingApprovals.isEmpty {
                    Label("\(session.pendingApprovals.count) waiting", systemImage: "hand.raised.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Picker("Agent", selection: $session.agentFilter) {
                    Text("All agents").tag(String?.none)
                    ForEach(session.agents) { agent in
                        Text(agent.name).tag(String?.some(agent.id))
                    }
                }
                .pickerStyle(.menu)
                Button {
                    session.clearActivity()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(session.isRunning)
                .accessibilityLabel("Clear the activity feed")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ActivityList(items: session.filteredActivity, showAgent: session.agentFilter == nil && session.agents.count > 1)
        }
    }
}

/// A scrolling list of activity rows (also the per-member lanes of the Team screen).
struct ActivityList: View {
    var items: [ActivityItem]
    var showAgent: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if items.isEmpty {
                        Text("Nothing yet. Steps appear here as the agent works.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(items) { item in
                        ActivityRow(item: item, showAgent: showAgent)
                            .id(item.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: items.count) {
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: lastDeltaLength) {
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Changes while a text row streams, to keep the list pinned to the bottom.
    private var lastDeltaLength: Int {
        guard let last = items.last else { return 0 }
        switch last.kind {
        case .text(let text), .reasoning(let text): return text.count
        default: return 0
        }
    }
}

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
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .secondarySystemBackground)))
        case .reasoning(let text):
            CollapsibleText(title: "Thinking", text: text, systemImage: "brain")
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
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .italic()
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("\(title) · \(Format.clip(text.replacingOccurrences(of: "\n", with: " "), 50))", systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ToolCallRow: View {
    var call: ToolCall
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.purple)
                    Text(call.name).font(.callout.monospaced().weight(.semibold)).foregroundStyle(.primary)
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                Text(call.arguments.jsonString(pretty: true))
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
            if let text = a["text"]?.stringValue { s += " “\(Format.clip(text, 30))”" }
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
                Text(expanded || text.count <= 300 ? (text.isEmpty ? "(no text)" : text) : Format.clip(text, 300))
                    .font(.caption.monospaced())
                    .foregroundStyle(result.isError ? Color.red : Color.primary)
                    .textSelection(.enabled)
                if text.count > 300 {
                    Button(expanded ? "Show less" : "Show all (\(text.count) characters)") { expanded.toggle() }
                        .font(.caption)
                }
            }
        }
        .padding(.leading, 4)
    }
}

/// A screenshot the agent looked at; tap for a full-screen view.
struct ScreenshotThumbnail: View {
    var image: ImageData
    @State private var showing = false

    var body: some View {
        if let uiImage = UIImage(data: image.data) {
            Button {
                showing = true
            } label: {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 150, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Screenshot \(image.width ?? 0) by \(image.height ?? 0)")
            .fullScreenCover(isPresented: $showing) {
                ImageViewer(image: uiImage, caption: "\(image.width ?? 0) × \(image.height ?? 0) px, as sent to the model")
            }
        } else {
            Label("Screenshot (\(image.data.count) bytes, unreadable)", systemImage: "photo")
                .foregroundStyle(.secondary)
        }
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
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { session.decide(request, .deny) }
                        .buttonStyle(.bordered)
                    Button("Always") { session.decide(request, .approveAlways) }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Allow this kind of action for the rest of the session")
                }
                .controlSize(.small)
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
