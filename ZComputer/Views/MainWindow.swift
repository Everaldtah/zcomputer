import SwiftUI
import ZVM

/// The main window: sidebar sections Machines / Agent / Team / Library / Terminal / Settings.
struct MainWindow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var agent = model.agent
        NavigationSplitView {
            List(selection: $model.selection) {
                Section("Z Computer") {
                    ForEach(SidebarItem.allCases) { item in
                        SidebarRow(item: item)
                            .tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
                    .padding(10)
            }
        } detail: {
            detail(for: model.selection ?? .agent)
        }
        .sheet(item: $agent.consentRequest) { request in
            CloudConsentSheet(request: request)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .machines: MachinesView()
        case .agent: AgentView()
        case .team: TeamView()
        case .library: LibraryView()
        case .terminal: TerminalScreen()
        case .settings: SettingsView()
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        HStack {
            Label(item.title, systemImage: item.systemImage)
            Spacer()
            switch item {
            case .agent where model.agent.isRunning:
                StatusDot(color: model.agent.isPaused ? .orange : .green)
            case .agent where !model.agent.pendingApprovals.isEmpty:
                Text("\(model.agent.pendingApprovals.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.orange))
                    .foregroundStyle(.white)
            case .team where model.team.isRunning:
                StatusDot(color: .green)
            case .machines where model.machines.states.values.contains(where: \.isActive):
                StatusDot(color: .green)
            default:
                EmptyView()
            }
        }
    }
}

/// Bottom of the sidebar: the agent's machine indicator (App Review 2.5.14: visible while an agent watches).
private struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.agent.isControllingMachine, let name = model.agent.controlledMachineName {
            HStack(spacing: 6) {
                StatusDot(color: .red)
                Text("Agent is controlling \(name)")
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Button("Stop") { model.agent.stop() }
                    .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.12)))
        }
    }
}

struct StatusDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
}
