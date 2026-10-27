import SwiftUI
import ZVM

/// Terminal tabs: a shell on this Mac (inside the app sandbox) and each running VM's serial console.
struct TerminalScreen: View {
    enum Tab: Hashable {
        case host
        case vm(UUID)
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .host

    var body: some View {
        let machines = model.machines
        let shell = model.shell
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Terminal", selection: $tab) {
                    Label("This Mac (zsh)", systemImage: "laptopcomputer").tag(Tab.host)
                    ForEach(machines.specs.filter { machines.state($0.id).isActive }) { spec in
                        Label("\(spec.name) console", systemImage: "cable.connector").tag(Tab.vm(spec.id))
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                if tab == .host {
                    if let error = shell.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if !shell.isRunning, let status = shell.exitStatus {
                        Text("Exited (\(status))").font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        shell.restart()
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .help("Start a new shell")
                }
            }
            .padding(8)
            Divider()
            switch tab {
            case .host:
                TerminalHostView(endpoint: shell)
                    .id("host")
            case .vm(let id):
                if let endpoint = machines.consoleEndpoint(for: id) {
                    TerminalHostView(endpoint: endpoint)
                        .id(id)
                } else {
                    ContentUnavailableView("Console unavailable", systemImage: "cable.connector.slash",
                                           description: Text("Start the VM in Machines to see its serial console."))
                }
            }
            Text(tab == .host
                 ? "The shell runs inside the app sandbox: it sees the app's container, not your whole home folder."
                 : "Serial console (hvc0). Log in with the guest's user; the agent uses the guest agent when it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .navigationTitle("Terminal")
        .onChange(of: machines.specs.map(\.id)) {
            if case .vm(let id) = tab, machines.spec(id) == nil { tab = .host }
        }
    }
}
