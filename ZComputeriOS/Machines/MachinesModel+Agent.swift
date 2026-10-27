import Foundation
import ZCore

/// Which machine the Agent view's runner controls.
enum AgentMachineChoice: Hashable {
    case none
    case demo
    case machine(UUID)

    init(key: String?) {
        switch key {
        case nil, "demo": self = .demo
        case "none": self = .none
        case let key?: self = UUID(uuidString: key).map { .machine($0) } ?? .demo
        }
    }

    var key: String {
        switch self {
        case .none: return "none"
        case .demo: return "demo"
        case .machine(let id): return id.uuidString
        }
    }
}

/// A machine the Machines screen can open full screen.
enum MachineEntry: Hashable, Identifiable {
    case demo
    case machine(UUID)

    var id: String {
        switch self {
        case .demo: return "demo"
        case .machine(let id): return id.uuidString
        }
    }
}

// The members `AgentSession` and `TeamModel` (shared with the Mac app) use: the chosen machine's name, a key for
// the runner cache and the `ComputerSurface` the agent drives.
extension MachinesModel {
    func setAgentChoice(_ choice: AgentMachineChoice) {
        agentChoice = choice
        UserDefaults.standard.set(choice.key, forKey: SettingsKey.agentMachine)
    }

    var agentChoiceKey: String { agentChoice.key }

    /// Name of the machine the agent will control (nil = no machine, chat only).
    var agentMachineName: String? {
        switch agentChoice {
        case .none: return nil
        case .demo: return demo.name
        case .machine(let id): return summary(id)?.name ?? "Machine"
        }
    }

    /// The `ComputerSurface` for the agent: the Demo machine, or a running emulated machine's surface.
    func agentSurface() throws -> (any ComputerSurface)? {
        switch agentChoice {
        case .none:
            return nil
        case .demo:
            return demo
        case .machine(let id):
            let name = summary(id)?.name ?? "the machine"
            guard state(id).isActive, let surface = surface(for: id) else {
                throw ZError.vm("Start “\(name)” in Machines before giving it to the agent.")
            }
            return surface
        }
    }

    /// The surface the touch layer and keyboard drive for an open machine (nil until its runtime exists).
    func inputSurface(for entry: MachineEntry) -> (any ComputerSurface)? {
        switch entry {
        case .demo: return demo
        case .machine(let id): return surface(for: id)
        }
    }

    /// Display name of an entry.
    func name(of entry: MachineEntry) -> String {
        switch entry {
        case .demo: return demo.name
        case .machine(let id): return summary(id)?.name ?? "Machine"
        }
    }
}
