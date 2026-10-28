import SwiftUI
import ZCore

/// The machine list: the Demo machine and the user's emulated x86 machines (state, memory, agent badge). Tapping a
/// machine opens it full screen; "+" opens the image library.
struct MachinesScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showingLibrary = false

    var body: some View {
        let machines = model.machines
        NavigationStack {
            List {
                if let reason = machines.engine.unavailableReason {
                    Section {
                        Label(reason, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        machines.presented = .demo
                    } label: {
                        MachineRow(title: "Demo machine", subtitle: "Simulated desktop for trying the agent",
                                   systemImage: "sparkles.tv", stateLabel: "Always on", stateColor: .green,
                                   isAgentMachine: machines.agentChoice == .demo)
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    if machines.machines.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No machines yet").font(.headline)
                            Text("Tap + to get Z Alpine Desktop (starts in seconds) or boot an ISO. Machines are "
                                 + "32-bit x86 PCs emulated inside the app; they keep running while you use other tabs.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Open the image library") { showingLibrary = true }
                                .disabled(!machines.isEngineAvailable)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(machines.machines) { machine in
                        Button {
                            machines.presented = .machine(machine.id)
                        } label: {
                            MachineRow(title: machine.name,
                                       subtitle: "\(machine.bootDescription) · \(machine.memoryMB) MB",
                                       systemImage: "desktopcomputer",
                                       stateLabel: machines.state(machine.id).label,
                                       stateColor: color(machines.state(machine.id)),
                                       isAgentMachine: machines.agentChoice == .machine(machine.id))
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { machines.delete(machine.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { contextMenu(for: machine) }
                    }
                } header: {
                    Text("Your machines")
                } footer: {
                    if let error = machines.listError { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Machines")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLibrary = true
                    } label: {
                        Label("Image library", systemImage: "plus")
                    }
                }
            }
            .refreshable { machines.reload() }
            .sheet(isPresented: $showingLibrary, onDismiss: openCreatedMachine) {
                ImageLibrarySheet()
            }
            .alert("Machines", isPresented: Binding(get: { machines.message != nil },
                                                    set: { if !$0 { machines.message = nil } })) {
                Button("OK") { machines.message = nil }
            } message: {
                Text(machines.message ?? "")
            }
        }
    }

    /// A machine made in the library opens full screen once the sheet is gone (one presentation at a time).
    private func openCreatedMachine() {
        let machines = model.machines
        guard let id = machines.justCreated else { return }
        machines.justCreated = nil
        machines.presented = .machine(id)
    }

    @ViewBuilder
    private func contextMenu(for machine: MachineSummary) -> some View {
        let machines = model.machines
        let state = machines.state(machine.id)
        if state.isActive {
            Button { machines.stop(machine.id) } label: { Label("Power off", systemImage: "power") }
            Button { machines.saveState(machine.id) } label: { Label("Save state", systemImage: "square.and.arrow.down") }
        } else {
            Button { machines.start(machine.id) } label: { Label("Start", systemImage: "power") }
        }
        Button { machines.setAgentChoice(.machine(machine.id)) } label: {
            Label("Give to the agent", systemImage: "sparkles")
        }
        Button(role: .destructive) { machines.delete(machine.id) } label: { Label("Delete", systemImage: "trash") }
    }

    private func color(_ state: MachineRunState) -> Color {
        switch state {
        case .running: return .green
        case .starting, .saving: return .blue
        case .paused: return .orange
        case .error: return .red
        case .stopped: return .gray
        }
    }
}

private struct MachineRow: View {
    @Environment(AppModel.self) private var model
    var title: String
    var subtitle: String
    var systemImage: String
    var stateLabel: String
    var stateColor: Color
    var isAgentMachine: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold)).lineLimit(1)
                    if isAgentMachine {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(Color.accentColor)
                            .accessibilityLabel("The agent's machine")
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    StatusDot(color: stateColor)
                    Text(stateLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if isAgentMachine && model.agent.isControllingMachine {
                        Text("· agent working").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
