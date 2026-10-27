import SwiftUI
import ZCore
import ZTeam

/// Team mode: goal and controls, the task board (columns scroll sideways), member editor and per-member lanes.
struct TeamScreen: View {
    @Environment(AppModel.self) private var model
    @State private var message = ""

    var body: some View {
        @Bindable var team = model.team
        NavigationStack {
            List {
                Section {
                    TextField("What should the team achieve?", text: $team.goal, axis: .vertical)
                        .lineLimit(2...6)
                    Stepper("Parallel workers: \(team.maxParallelWorkers)", value: $team.maxParallelWorkers, in: 1...6)
                    Toggle("Use the agent's machine", isOn: $team.useMachine)
                    controls(team)
                } header: {
                    HStack {
                        Text("Goal")
                        Spacer()
                        Text(phaseLabel(team.phase))
                    }
                } footer: {
                    Text("Members share the machine chosen in the Agent tab; their input is serialised by a lease.")
                }

                if let error = team.lastError {
                    Section {
                        MessageBanner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                            .listRowInsets(EdgeInsets())
                    }
                }

                if team.isRunning {
                    Section("Message the team") {
                        HStack {
                            TextField("Answers questions too", text: $message)
                                .onSubmit(sendMessage)
                            Button("Send", action: sendMessage).disabled(message.isEmpty)
                        }
                    }
                }

                Section("Board") {
                    TaskBoardView()
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                if let outcome = team.outcome {
                    Section(outcome.success ? "Team report" : (outcome.stopped ? "Stopped" : "The team could not finish")) {
                        OutcomeSummary(outcome: outcome)
                    }
                }

                Section {
                    ForEach($team.members) { $member in
                        NavigationLink {
                            MemberEditor(member: $member)
                        } label: {
                            MemberRow(member: member)
                        }
                    }
                    .onDelete { model.team.removeMembers(at: $0) }
                    .deleteDisabled(team.isRunning)
                    Button {
                        team.addMember()
                    } label: {
                        Label("Add member", systemImage: "plus")
                    }
                    .disabled(team.isRunning)
                } header: {
                    Text("Members")
                } footer: {
                    Text("Tap a member to edit the role, model and instructions. Lanes show each member's activity.")
                }

                Section("Member lanes") {
                    ForEach(team.members) { member in
                        NavigationLink {
                            MemberLane(member: member)
                        } label: {
                            HStack {
                                Text(member.name)
                                Spacer()
                                StatusPill(status: model.agent.statuses[member.id] ?? .idle, running: team.isRunning)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Team")
            .onChange(of: team.members) { model.team.save() }
        }
    }

    @ViewBuilder
    private func controls(_ team: TeamModel) -> some View {
        if team.isRunning {
            HStack {
                if team.isPaused {
                    Button { team.resume() } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { team.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                }
                Spacer()
                Button(role: .destructive) { team.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            }
            .buttonStyle(.borderless)
        } else {
            Button {
                team.run()
            } label: {
                Label("Run Team", systemImage: "person.3.sequence.fill")
            }
            .disabled(team.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendMessage() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.team.send(text, to: nil)
        message = ""
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

private struct MemberRow: View {
    @Environment(AppModel.self) private var model
    var member: TeamMember

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                StatusDot(color: statusColor)
                Text(member.name).font(.body.weight(.semibold))
                Text(member.role.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Text(member.model.model.isEmpty ? "No model chosen" : model.displayName(for: member.model))
                .font(.caption)
                .foregroundStyle(member.model.model.isEmpty ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
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

/// Name, role, model, instructions.
private struct MemberEditor: View {
    @Binding var member: TeamMember

    var body: some View {
        Form {
            TextField("Name", text: $member.name)
            Picker("Role", selection: roleBinding) {
                Text("Lead").tag("lead")
                Text("Worker").tag("worker")
                Text("Reviewer").tag("reviewer")
                if case .custom(let name) = member.role { Text(name).tag(name) }
            }
            Section("Model") {
                ModelMenu(selection: member.model.model.isEmpty ? nil : member.model) { ref in member.model = ref }
            }
            Section("Instructions") {
                TextEditor(text: $member.instructions)
                    .frame(minHeight: 140)
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var roleBinding: Binding<String> {
        Binding(get: { member.role.rawValue }, set: { member.role = TeamRole(rawValue: $0) })
    }
}

/// One member's activity.
private struct MemberLane: View {
    @Environment(AppModel.self) private var model
    var member: TeamMember

    var body: some View {
        ActivityList(items: model.agent.activity(for: member.id, limit: 200), showAgent: false)
            .navigationTitle(member.name)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// todo / doing / blocked / done (+ failed) columns, scrolling sideways.
private struct TaskBoardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let team = model.team
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    let tasks = team.tasks(in: status)
                    if status != .failed || !tasks.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(status.rawValue.capitalized).font(.subheadline.weight(.semibold))
                                Text("\(tasks.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            if tasks.isEmpty {
                                Text("—").foregroundStyle(.tertiary)
                            }
                            ForEach(tasks) { task in TaskCard(task: task) }
                        }
                        .padding(8)
                        .frame(width: 220, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                    }
                }
            }
            .padding(.horizontal, 12)
        }
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
            }
            if !task.dependsOn.isEmpty {
                Text("after #\(task.dependsOn.joined(separator: ", #"))").font(.caption2).foregroundStyle(.secondary)
            }
            if let result = task.result, !result.isEmpty {
                Text(result).font(.caption).lineLimit(4).textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(uiColor: .secondarySystemGroupedBackground)))
    }
}

private struct OutcomeSummary: View {
    var outcome: TeamOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(outcome.report).textSelection(.enabled)
            if let review = outcome.review, !review.isEmpty {
                Text("Review: \(review)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Tokens: \(outcome.usage.inputTokens) in, \(outcome.usage.outputTokens) out · \(Int(outcome.duration)) s")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}
