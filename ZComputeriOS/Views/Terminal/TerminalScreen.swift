import SwiftUI

/// Terminal views kept for the session (one per machine runtime), so scrollback survives tab switches.
@MainActor
final class TerminalSessions {
    private var controllers: [String: ConsoleTerminalController] = [:]

    /// The terminal for an entry: the Demo machine's simulated shell, or a running machine's serial console.
    func controller(for entry: MachineEntry, machines: MachinesModel) -> ConsoleTerminalController? {
        switch entry {
        case .demo:
            if let existing = controllers["demo"] { return existing }
            let controller = ConsoleTerminalController(endpoint: DemoConsoleEndpoint(surface: machines.demo))
            controllers["demo"] = controller
            return controller
        case .machine(let id):
            guard let runtime = machines.existingRuntime(for: id) else { return nil }
            let key = "\(id.uuidString)#\(ObjectIdentifier(runtime).hashValue)"
            if let existing = controllers[key] { return existing }
            let controller = ConsoleTerminalController(endpoint: MachineConsoleEndpoint(runtime: runtime))
            controllers[key] = controller
            return controller
        }
    }
}

/// SwiftTerm bound to the chosen machine's serial console (ttyS0), or the Demo machine's simulated shell.
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selection: MachineEntry = .demo
    @State private var sessions = TerminalSessions()

    var body: some View {
        let machines = model.machines
        NavigationStack {
            Group {
                if let controller = sessions.controller(for: selection, machines: machines) {
                    ConsoleTerminalView(controller: controller)
                        .id(selection.id)
                        .ignoresSafeArea(.container, edges: .bottom)
                } else {
                    ContentUnavailableView {
                        Label("\(machines.name(of: selection)) is not running", systemImage: "terminal")
                    } description: {
                        Text("Start it in Machines; its serial console (ttyS0) appears here.")
                    } actions: {
                        if case .machine(let id) = selection {
                            Button("Start") { machines.start(id) }
                        }
                    }
                }
            }
            .navigationTitle(machines.name(of: selection))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Console", selection: $selection) {
                            Text("Demo machine (simulated)").tag(MachineEntry.demo)
                            ForEach(machines.machines) { machine in
                                Text("\(machine.name) (\(machines.state(machine.id).label))").tag(MachineEntry.machine(machine.id))
                            }
                        }
                    } label: {
                        Label("Console", systemImage: "rectangle.stack")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sessions.controller(for: selection, machines: machines)?.focus()
                    } label: {
                        Label("Keyboard", systemImage: "keyboard")
                    }
                }
            }
        }
    }
}
