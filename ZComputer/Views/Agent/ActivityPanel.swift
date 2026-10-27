import SwiftUI
import ZCore

/// The "what is the agent doing" panel: a live timeline of every agent's events (thinking, text, tool calls with
/// arguments, results, screenshots, approvals) with a per-agent filter.
struct ActivityPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var session = model.agent
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Activity").font(.headline)
                if !session.pendingApprovals.isEmpty {
                    Text("\(session.pendingApprovals.count) waiting")
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
                .labelsHidden()
                .frame(maxWidth: 170)
                Button {
                    session.clearActivity()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear the activity feed")
                .disabled(session.isRunning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            ActivityList(items: session.filteredActivity, showAgent: session.agentFilter == nil && session.agents.count > 1)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
    }
}

/// A scrolling list of activity rows (also used for the per-member lanes of the Team view).
struct ActivityList: View {
    var items: [ActivityItem]
    var showAgent: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
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
                .padding(10)
            }
            .onChange(of: items.count) {
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: lastDeltaLength) {
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// Changes while a text row streams, to keep the view pinned to the bottom.
    private var lastDeltaLength: Int {
        guard let last = items.last else { return 0 }
        switch last.kind {
        case .text(let text), .reasoning(let text): return text.count
        default: return 0
        }
    }
}
