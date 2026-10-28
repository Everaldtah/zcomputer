import SwiftUI
import ZCore

/// Chat + Activity (segmented), model and machine pickers, run controls; `ask_user` is answered from the composer.
struct AgentScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pane: Pane = .chat
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    enum Pane: String, CaseIterable, Identifiable {
        case chat = "Chat"
        case activity = "Activity"
        var id: String { rawValue }
    }

    var body: some View {
        let session = model.agent
        NavigationStack {
            VStack(spacing: 0) {
                AgentHeader()
                Picker("View", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        if pane == .activity && !session.pendingApprovals.isEmpty {
                            Text("Activity (\(session.pendingApprovals.count))").tag(pane)
                        } else {
                            Text(pane.rawValue).tag(pane)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                Divider()
                Group {
                    switch pane {
                    case .chat: ChatTranscript(lines: session.chat)
                    case .activity: ActivityPanel()
                    }
                }
                .frame(maxHeight: .infinity)
                if let question = session.pendingQuestion {
                    MessageBanner(text: "\(question.agentName) asks: \(question.question)\nType your answer below.",
                                  systemImage: "questionmark.bubble.fill", tint: .blue)
                }
                if let error = session.lastError {
                    MessageBanner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                Composer(draft: $draft, running: session.isRunning, answering: session.pendingQuestion != nil,
                         focused: $composerFocused) {
                    session.submit(draft)
                    draft = ""
                }
            }
            .overlay(alignment: .top) {
                if session.isControllingMachine {
                    AgentControllingBanner().padding(.top, 2)
                }
            }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { runControls(session) }
            .onChange(of: session.pendingApprovals.count) { old, new in
                if new > old { pane = .activity }
            }
        }
    }

    /// Pause / Resume / Stop / New conversation.
    @ToolbarContentBuilder
    private func runControls(_ session: AgentSession) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if session.isRunning {
                if session.isPaused {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                }
                Button(role: .destructive) { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            } else {
                Button { session.newConversation() } label: { Label("New conversation", systemImage: "square.and.pencil") }
            }
        }
    }
}

/// Model + machine pickers and the status.
private struct AgentHeader: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.agentProvider) private var providerRaw = ""
    @AppStorage(SettingsKey.agentModel) private var modelID = ""

    var body: some View {
        let session = model.agent
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ModelMenu(selection: currentRef) { ref in
                    providerRaw = ref.provider.rawValue
                    modelID = ref.model
                }
                Spacer(minLength: 4)
                StatusPill(status: session.mainStatus, running: session.isRunning)
            }
            AgentMachineMenu()
                .disabled(session.isRunning)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var currentRef: ModelRef? {
        guard !providerRaw.isEmpty, !modelID.isEmpty else { return nil }
        return ModelRef(provider: ProviderID(providerRaw), model: modelID)
    }
}

// MARK: Transcript

private struct ChatTranscript: View {
    var lines: [ChatLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        EmptyChatHint()
                    }
                    ForEach(lines) { line in
                        ChatBubble(line: line)
                            .id(line.id)
                    }
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: lines.last?.text) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: lines.count) {
                if let last = lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

private struct EmptyChatHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give the agent a task").font(.title3.weight(.semibold))
            Text("Pick a model and a machine above, then describe what to do, for example: "
                 + "“Open the terminal and tell me which kernel the machine runs.”")
                .foregroundStyle(.secondary)
            Text("Activity shows every step: what the agent thinks, the tools it calls, screenshots and approvals. "
                 + "Destructive commands wait for your approval.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

private struct ChatBubble: View {
    var line: ChatLine

    var body: some View {
        HStack(alignment: .top) {
            if line.role == .user { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text.isEmpty && line.live ? "…" : line.text)
                    .textSelection(.enabled)
                    .font(line.role == .system || line.role == .error ? .callout : .body)
                    .foregroundStyle(foreground)
                Text(Format.time(line.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(background))
            if line.role != .user { Spacer(minLength: 32) }
        }
    }

    private var background: Color {
        switch line.role {
        case .user: return .accentColor.opacity(0.18)
        case .assistant: return Color(uiColor: .secondarySystemBackground)
        case .system: return .blue.opacity(0.08)
        case .error: return .red.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch line.role {
        case .error: return .red
        case .system: return .secondary
        case .user, .assistant: return .primary
        }
    }
}

// MARK: Composer

private struct Composer: View {
    @Binding var draft: String
    var running: Bool
    var answering: Bool
    var focused: FocusState<Bool>.Binding
    var send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground)))
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: running ? "arrow.up.message.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel(running ? "Send to the running agent" : "Start the task")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var placeholder: String {
        if answering { return "Answer the agent's question…" }
        return running ? "Message the agent while it works…" : "Describe a task for the agent…"
    }
}
