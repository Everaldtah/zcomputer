import SwiftUI
import ZCore
import ZTeam

/// Team mode: member editor, goal, task board columns and per-member activity lanes.
struct TeamView: View {
    @Environment(AppModel.self) private var model
    @State private var message = ""

    var body: some View {
        @Bindable var team = model.team
        VSplitView {
            HSplitView {
                MemberEditorList()
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
                VStack(alignment: .leading, spacing: 10) {
                    GoalBar()
                    if let error = team.lastError {
                        MessageBanner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    TaskBoardView()
                    if let outcome = team.outcome {
                        OutcomeSummary(outcome: outcome)
                    }
                }
                .padding(12)
                .frame(minWidth: 520)
            }
            .frame(minHeight: 360)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Member lanes").font(.headline)
                    Spacer()
                    if team.isRunning {
                        TextField("Message the team (answers questions too)", text: $message)
                            .frame(maxWidth: 360)
                            .onSubmit(sendMessage)
                        Button("Send", action: sendMessage).disabled(message.isEmpty)
                    }
                }
                MemberLanes()
            }
            .padding(12)
            .frame(minHeight: 200)
        }
        .navigationTitle("Team")
    }

    private func sendMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.team.send(text, to: nil)
        message = ""
    }
}

private struct GoalBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var team = model.team
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Goal").font(.headline)
                Text(phaseLabel(team.phase)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper("Parallel workers: \(team.maxParallelWorkers)", value: $team.maxParallelWorkers, in: 1...6)
                    .fixedSize()
                Toggle("Use the agent's machine", isOn: $team.useMachine)
                    .help("Members share the machine chosen in the Agent view; input is serialised by a lease")
            }
            HStack(alignment: .top) {
                TextField("What should the team achieve?", text: $team.goal, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                if team.isRunning {
                    if team.isPaused {
                        Button { team.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    } else {
                        Button { team.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    }
                    Button(role: .destructive) { team.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                } else {
                    Button { team.run() } label: { Label("Run Team", systemImage: "person.3.sequence.fill") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(team.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func phaseLabel(_ phase: TeamPhase) -> String {
        switch phase {
        case .idle: return "Idle"
        case .planning: return "Planning"
        case .working: return "Working"
        case .reviewing: return "Reviewing"
        case .reporting: return "Writing the report"
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        }
    }
}

/// Editable roster: name, role, model, instructions.
private struct MemberEditorList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var team = model.team
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Members").font(.headline)
                Spacer()
                Button { team.addMember() } label: { Image(systemName: "plus") }
                    .disabled(team.isRunning)
            }
            .padding(12)
            List {
                ForEach($team.members) { $member in
                    MemberEditor(member: $member)
                        .contextMenu {
                            Button("Remove", role: .destructive) { model.team.remove(member) }
                        }
                }
                .onDelete { model.team.removeMembers(at: $0) }
            }
            .disabled(team.isRunning)
            .onChange(of: team.members) { model.team.save() }
        }
    }
}

private struct MemberEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var member: TeamMember
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name", text: $member.name)
                    .font(.body.weight(.semibold))
                    .textFieldStyle(.plain)
                Picker("", selection: roleBinding) {
                    Text("Lead").tag("lead")
                    Text("Worker").tag("worker")
                    Text("Reviewer").tag("reviewer")
                    if case .custom(let name) = member.role { Text(name).tag(name) }
                }
                .labelsHidden()
                .frame(width: 110)
                StatusDot(color: statusColor)
            }
            ModelMenu(selection: member.model.model.isEmpty ? nil : member.model) { ref in member.model = ref }
            DisclosureGroup("Instructions", isExpanded: $expanded) {
                TextEditor(text: $member.instructions)
                    .frame(minHeight: 60)
                    .font(.callout)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var roleBinding: Binding<String> {
        Binding(get: { member.role.rawValue }, set: { member.role = TeamRole(rawValue: $0) })
    }

    private var statusColor: Color {
        switch model.agent.statuses[member.id] {
        case .thinking?, .acting?: return .green
        case .waitingForApproval?, .paused?: return .orange
        case .failed?: return .red
        default: return .gray
        }
    }
}

/// todo / doing / blocked / done (+ failed) columns.
private struct TaskBoardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let team = model.team
        HStack(alignment: .top, spacing: 10) {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                let tasks = team.tasks(in: status)
                if status != .failed || !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(status.rawValue.capitalized).font(.subheadline.weight(.semibold))
                            Text("\(tasks.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(tasks) { task in TaskCard(task: task) }
                            }
                        }
                    }
                    .padding(8)
                    .frame(minWidth: 130, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                }
            }
        }
        .frame(minHeight: 180)
    }
}

private struct TaskCard: View {
    @Environment(AppModel.self) private var model
    var task: TeamTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("#\(task.id) \(task.title)").font(.callout.weight(.medium)).lineLimit(3)
            if !task.detail.isEmpty {
                Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 6) {
                Label(model.team.memberName(task.assignee), systemImage: "person").font(.caption2)
                if task.attempts > 1 { Text("attempt \(task.attempts)").font(.caption2).foregroundStyle(.orange) }
                if !task.dependsOn.isEmpty {
                    Text("after #\(task.dependsOn.joined(separator: ", #"))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let result = task.result, !result.isEmpty {
                Text(result).font(.caption).lineLimit(4).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// One column per member with that member's latest activity.
private struct MemberLanes: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let members = model.team.members
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(member.name).font(.subheadline.weight(.semibold))
                            Text(member.role.rawValue).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            StatusPill(status: model.agent.statuses[member.id] ?? .idle, running: model.team.isRunning)
                        }
                        ActivityList(items: model.agent.activity(for: member.id), showAgent: false)
                    }
                    .padding(8)
                    .frame(width: 360)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
            }
        }
    }
}

private struct OutcomeSummary: View {
    var outcome: TeamOutcome

    var body: some View {
        GroupBox {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(outcome.report).textSelection(.enabled)
                    if let review = outcome.review, !review.isEmpty {
                        Text("Review: \(review)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("Tokens: \(outcome.usage.inputTokens) in, \(outcome.usage.outputTokens) out · "
                         + "\(Int(outcome.duration)) s")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
        } label: {
            Label(outcome.success ? "Team report" : (outcome.stopped ? "Stopped" : "The team could not finish"),
                  systemImage: outcome.success ? "checkmark.seal" : "exclamationmark.triangle")
        }
    }
}
