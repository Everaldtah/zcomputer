import SwiftUI
import ZCore

/// The visible "Agent is controlling" indicator with a recording dot and a Stop button (App Review 2.5.14: the user
/// must see when an agent watches and drives a machine). Shown on every tab while the agent works on a machine.
struct AgentControllingBanner: View {
    @Environment(AppModel.self) private var model
    var compact = false
    @State private var pulse = false

    var body: some View {
        let session = model.agent
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text(compact ? "Agent on \(session.controlledMachineName ?? "machine")"
                 : "Agent is controlling \(session.controlledMachineName ?? "the machine")")
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if !compact {
                Text(session.mainStatus.label).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                session.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.red.opacity(0.5)))
        .shadow(radius: 4, y: 2)
        .onAppear { pulse = true }
        .accessibilityElement(children: .combine)
    }
}

/// Asks before screenshots and files go to a cloud provider (App Review 5.1.2(i)). Local models need no consent.
struct CloudConsentSheet: View {
    @Environment(AppModel.self) private var model
    var request: ConsentRequest

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Send screenshots to \(request.providerName)?")
                        .font(.title2.weight(.semibold))
                    Text("To work on \(request.machineName), the agent takes screenshots of it and may read files and "
                         + "command output there. Those screenshots and texts are sent to \(request.providerName), a "
                         + "third-party AI service, together with your task, so the model can decide the next step.")
                    Text("Nothing is sent until you allow it. You can withdraw this permission in Settings ▸ Agent. "
                         + "Models on this device or on your own server (MLX, Apple on-device, Ollama, LM Studio) "
                         + "never need this permission.")
                        .foregroundStyle(.secondary)
                    GroupBox("Task") {
                        Text(request.task)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Button {
                        model.agent.resolveConsent(request, allow: true)
                    } label: {
                        Text("Allow for \(request.providerName)").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button(role: .cancel) {
                        model.agent.resolveConsent(request, allow: false)
                    } label: {
                        Text("Don't Allow").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(20)
            }
            .navigationTitle("Screenshots")
            .navigationBarTitleDisplayMode(.inline)
        }
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
                Text("No models: add a key in Settings ▸ Providers or a server in Settings ▸ Local models")
            }
        } label: {
            Label(selection.map { model.displayName(for: $0) } ?? "Choose a model", systemImage: "cpu")
                .lineLimit(1)
        }
    }

    private func orderedGroups(_ choices: [ModelChoice]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for choice in choices where seen.insert(choice.group).inserted { out.append(choice.group) }
        return out
    }
}

/// Which machine the agent controls.
struct AgentMachineMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let machines = model.machines
        Menu {
            Picker("Machine", selection: Binding(get: { machines.agentChoice }, set: { machines.setAgentChoice($0) })) {
                Text("No machine (chat only)").tag(AgentMachineChoice.none)
                Text("Demo machine").tag(AgentMachineChoice.demo)
                ForEach(machines.machines) { machine in
                    Text("\(machine.name) (\(machines.state(machine.id).label))").tag(AgentMachineChoice.machine(machine.id))
                }
            }
        } label: {
            Label(machines.agentMachineName ?? "No machine", systemImage: "desktopcomputer")
                .lineLimit(1)
        }
    }
}
