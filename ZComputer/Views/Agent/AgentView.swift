import SwiftUI
import ZCore
import ZVM

/// Chat composer + transcript on the left, the Activity panel on the right.
struct AgentView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        let session = model.agent
        HSplitView {
            VStack(spacing: 0) {
                AgentHeader()
                Divider()
                ChatTranscript(lines: session.chat)
                if let question = session.pendingQuestion {
                    QuestionBanner(question: question)
                }
                if let error = session.lastError {
                    MessageBanner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }
                Composer(draft: $draft, running: session.isRunning, answering: session.pendingQuestion != nil) {
                    session.submit(draft)
                    draft = ""
                }
            }
            .frame(minWidth: 380, idealWidth: 520)

            ActivityPanel()
                .frame(minWidth: 360, idealWidth: 480)
        }
        .overlay(alignment: .top) {
            if session.isControllingMachine {
                AgentControllingBanner()
                    .padding(.top, 54)
            }
        }
        .navigationTitle("Agent")
    }
}

/// Model + machine pickers, status and run controls.
private struct AgentHeader: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.agentProvider) private var providerRaw = ""
    @AppStorage(SettingsKey.agentModel) private var modelID = ""

    var body: some View {
        let session = model.agent
        HStack(spacing: 10) {
            ModelMenu(selection: currentRef) { ref in
                providerRaw = ref.provider.rawValue
                modelID = ref.model
            }
            .frame(maxWidth: 280)

            MachinePicker()
                .frame(maxWidth: 220)
                .disabled(session.isRunning)

            Spacer()

            StatusPill(status: session.mainStatus, running: session.isRunning)

            if session.isRunning {
                if session.isPaused {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                }
                Button(role: .destructive) { session.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button { session.newConversation() } label: { Label("New", systemImage: "square.and.pencil") }
                    .help("Start a new conversation")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var currentRef: ModelRef? {
        guard !providerRaw.isEmpty, !modelID.isEmpty else { return nil }
        return ModelRef(provider: ProviderID(providerRaw), model: modelID)
    }
}

/// A grouped menu of every model the app can use.
struct ModelMenu: View {
    @Environment(AppModel.self) private var model
    var selection: ModelRef?
    var onSelect: (ModelRef) -> Void

    var body: some View {
        let choices = model.pickerModels()
        let groups = orderedGroups(choices)
        Menu {
            ForEach(groups, id: \.self) { group in
                Menu(group) {
                    ForEach(choices.filter { $0.group == group }) { choice in
                        Button {
                            onSelect(choice.ref)
                        } label: {
                            Text(choice.free ? "\(choice.title)  (free)" : choice.title)
                        }
                    }
                }
            }
            if choices.isEmpty {
                Text("No models: add a key in Settings ▸ Providers or start Ollama / LM Studio")
            }
        } label: {
            Label(selection.map { model.displayName(for: $0) } ?? "Choose a model", systemImage: "cpu")
                .lineLimit(1)
        }
        .help("The model the agent uses")
    }

    private func orderedGroups(_ choices: [ModelChoice]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for choice in choices where seen.insert(choice.group).inserted { out.append(choice.group) }
        return out
    }
}

/// Which machine the agent controls.
private struct MachinePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let machines = model.machines
        Picker(selection: Binding(get: { machines.agentChoice }, set: { machines.setAgentChoice($0) })) {
            Text("No machine (chat only)").tag(AgentMachineChoice.none)
            Text("Demo machine").tag(AgentMachineChoice.demo)
            if machines.isSupported {
                ForEach(machines.specs) { spec in
                    Text("\(spec.name) (\(machines.state(spec.id).description))").tag(AgentMachineChoice.vm(spec.id))
                }
            }
        } label: {
            Image(systemName: "desktopcomputer")
        }
        .help("The machine the agent sees and controls")
    }
}

struct StatusPill: View {
    var status: AgentStatus
    var running: Bool

    var body: some View {
        Text(running || status != .idle ? status.label : "Ready")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .thinking, .acting: return .green
        case .waitingForApproval, .paused: return .orange
        case .failed: return .red
        case .finished: return .blue
        case .idle, .stopped: return .secondary
        }
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
                .padding(14)
            }
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
            Text("The Activity panel shows every step: what the agent thinks, the tools it calls, screenshots and "
                 + "approvals. Destructive commands wait for your approval.")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 30)
    }
}

private struct ChatBubble: View {
    var line: ChatLine

    var body: some View {
        HStack(alignment: .top) {
            if line.role == .user { Spacer(minLength: 40) }
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
            .background(RoundedRectangle(cornerRadius: 10).fill(background))
            if line.role != .user { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        switch line.role {
        case .user: return .accentColor.opacity(0.18)
        case .assistant: return Color(nsColor: .controlBackgroundColor)
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

private struct QuestionBanner: View {
    var question: PendingQuestion

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.bubble.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(question.agentName) asks").font(.caption.weight(.semibold))
                Text(question.question).textSelection(.enabled)
                Text("Type your answer below.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.blue.opacity(0.1))
    }
}

struct MessageBanner: View {
    var text: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
        }
        .padding(10)
        .background(tint.opacity(0.1))
    }
}

private struct Composer: View {
    @Binding var draft: String
    var running: Bool
    var answering: Bool
    var send: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: running ? "arrow.up.message.fill" : "paperplane.fill")
                    .frame(width: 22, height: 22)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(running ? "Send to the running agent" : "Start the task")
        }
        .padding(10)
    }

    private var placeholder: String {
        if answering { return "Answer the agent's question…" }
        return running ? "Message the agent while it works…" : "Describe a task for the agent…"
    }
}
