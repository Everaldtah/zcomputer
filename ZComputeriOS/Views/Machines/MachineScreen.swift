import SwiftUI
import UIKit
import ZCore

/// Per-screen state of the full-screen machine view: input pipeline, keyboard and the Demo machine's image feed.
@Observable
@MainActor
final class MachineScreenController {
    let input = MachineInput()
    let catcher = KeyboardCatcher()
    let demoFeed = DemoScreenFeed()
    private(set) var keyboardShown = false

    init() {
        catcher.input = input
    }

    func toggleKeyboard() {
        if catcher.isFirstResponder {
            catcher.resignFirstResponder()
            keyboardShown = false
        } else {
            keyboardShown = catcher.becomeFirstResponder()
        }
    }
}

/// A machine full screen: the live screen (pinch to zoom, touch → mouse), the key row, run controls, and the
/// "Agent is controlling" frame + banner. Closing it leaves the machine running (its view is parked).
struct MachineScreen: View {
    @Environment(AppModel.self) private var model
    let entry: MachineEntry
    @State private var controller = MachineScreenController()
    @State private var sendingText = false
    @State private var textToSend = ""

    var body: some View {
        let machines = model.machines
        let name = machines.name(of: entry)
        VStack(spacing: 0) {
            TopBar(entry: entry, name: name) { machines.presented = nil }
            ZStack {
                Color.black
                screen(machines)
                KeyboardCatcherHost(catcher: controller.catcher)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            }
            .overlay {
                if isControlled(name) {
                    Rectangle().strokeBorder(Color.red.opacity(0.85), lineWidth: 3).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if isControlled(name) { AgentControllingBanner().padding(.top, 8) }
            }
            KeyRow(input: controller.input, keyboardShown: controller.keyboardShown,
                   toggleKeyboard: { controller.toggleKeyboard() }, sendText: { sendingText = true })
            if case .machine(let id) = entry {
                MachineControls(id: id)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear(perform: attach)
        .onDisappear {
            controller.input.detach()
            controller.demoFeed.stop()
        }
        .onChange(of: stateKey(machines)) { attach() }
        .alert("Type into the machine", isPresented: $sendingText) {
            TextField("Text", text: $textToSend)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Send") {
                controller.input.type(textToSend)
                textToSend = ""
            }
            Button("Send + Return") {
                controller.input.type(textToSend)
                controller.input.key("Return")
                textToSend = ""
            }
            Button("Cancel", role: .cancel) { textToSend = "" }
        } message: {
            Text("The text is typed as keystrokes (handy for long commands and passwords).")
        }
    }

    @ViewBuilder
    private func screen(_ machines: MachinesModel) -> some View {
        switch entry {
        case .demo:
            MachineScreenHost(screen: controller.demoFeed.imageView,
                              guestSize: CGSize(width: MockComputerSurface.screenSize.width,
                                                height: MockComputerSurface.screenSize.height),
                              input: controller.input, parking: nil)
        case .machine(let id):
            let state = machines.state(id)
            if state.isActive, let runtime = machines.existingRuntime(for: id) {
                // The size follows the guest's video mode (MachinesModel watches the runtime).
                let size = machines.screenSize(id)
                MachineScreenHost(screen: runtime.screenView,
                                  guestSize: CGSize(width: size.width, height: size.height),
                                  input: controller.input, parking: machines.parking)
            } else {
                MachineOffView(id: id, state: state)
            }
        }
    }

    private func isControlled(_ name: String) -> Bool {
        model.agent.isControllingMachine && model.agent.controlledMachineName == name
    }

    /// Changes when the machine's runtime appears or its state changes (the input surface is re-attached).
    private func stateKey(_ machines: MachinesModel) -> String {
        switch entry {
        case .demo: return "demo"
        case .machine(let id): return machines.state(id).label
        }
    }

    private func attach() {
        let machines = model.machines
        if case .demo = entry { controller.demoFeed.start(surface: machines.demo) }
        controller.input.attach(machines.inputSurface(for: entry))
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var model
    let entry: MachineEntry
    let name: String
    var close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: close) {
                Image(systemName: "chevron.down").font(.headline)
            }
            .accessibilityLabel("Close (the machine keeps running)")
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.machines.agentChoiceKey != choice.key {
                Button {
                    model.machines.setAgentChoice(choice)
                } label: {
                    Label("Give to agent", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Label("Agent's machine", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
    }

    private var choice: AgentMachineChoice {
        switch entry {
        case .demo: return .demo
        case .machine(let id): return .machine(id)
        }
    }

    private var subtitle: String {
        switch entry {
        case .demo: return "Simulated · tap, hold, drag, two-finger scroll"
        case .machine(let id):
            let machines = model.machines
            let state = machines.state(id)
            if let error = machines.errors[id] { return error }
            guard let summary = machines.summary(id) else { return state.label }
            return "\(state.label) · \(summary.memoryMB) MB · \(summary.screenWidth)×\(summary.screenHeight)"
        }
    }
}

/// Ctrl / Alt (one-shot), Esc, Tab, arrows, keyboard toggle and "send text".
private struct KeyRow: View {
    let input: MachineInput
    let keyboardShown: Bool
    var toggleKeyboard: () -> Void
    var sendText: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(keyboardShown ? "keyboard.chevron.compact.down" : "keyboard", label: "Keyboard", action: toggleKeyboard)
                key("text.cursor", label: "Send text", action: sendText)
                Divider().frame(height: 22)
                modifier("Ctrl", name: "ctrl")
                modifier("Alt", name: "alt")
                textKey("Esc") { input.key("Escape") }
                textKey("Tab") { input.key("Tab") }
                key("arrow.left", label: "Left") { input.key("Left") }
                key("arrow.up", label: "Up") { input.key("Up") }
                key("arrow.down", label: "Down") { input.key("Down") }
                key("arrow.right", label: "Right") { input.key("Right") }
                key("return", label: "Return") { input.key("Return") }
                key("delete.left", label: "Backspace") { input.key("BackSpace") }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(white: 0.12))
    }

    private func key(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(minWidth: 34, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
    }

    private func textKey(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.medium)).frame(minWidth: 34, minHeight: 30)
        }
        .buttonStyle(.bordered)
    }

    private func modifier(_ title: String, name: String) -> some View {
        let on = input.modifiers.contains(name)
        return Button {
            input.toggleModifier(name)
        } label: {
            Text(title).font(.callout.weight(.semibold)).frame(minWidth: 34, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .tint(on ? .accentColor : nil)
        .background(on ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.35)) : nil)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Start / Power off (save or discard), Pause / Resume, Save state.
private struct MachineControls: View {
    @Environment(AppModel.self) private var model
    let id: UUID

    var body: some View {
        let machines = model.machines
        let state = machines.state(id)
        HStack(spacing: 18) {
            if state.isActive {
                Menu {
                    Button { machines.stop(id, saveState: true) } label: {
                        Label("Save and power off", systemImage: "square.and.arrow.down")
                    }
                    Button(role: .destructive) { machines.stop(id, saveState: false) } label: {
                        Label("Power off without saving", systemImage: "power")
                    }
                } label: {
                    Label("Power off", systemImage: "power")
                }
                .disabled(state == .starting)
                if state == .paused {
                    Button { machines.resume(id) } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { machines.pause(id) } label: { Label("Pause", systemImage: "pause.fill") }
                        .disabled(state != .running)
                }
                Button { machines.saveState(id) } label: { Label("Save state", systemImage: "square.and.arrow.down") }
                    .disabled(state != .running && state != .paused)
            } else {
                Button { machines.start(id) } label: { Label("Start", systemImage: "power") }
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08))
    }
}

/// A stopped machine (or one that failed).
private struct MachineOffView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let state: MachineRunState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer").font(.system(size: 44)).foregroundStyle(.secondary)
            Text(state == .starting ? "Starting…" : "The machine is off").font(.headline)
            if state != .starting, let summary = model.machines.summary(id) {
                Text(summary.hasSavedState ? "Start resumes where it was saved." : "Start boots \(summary.bootDescription).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = model.machines.errors[id] {
                Text(error).font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center).padding(.horizontal)
            }
            if state != .starting {
                Button { model.machines.start(id) } label: { Label("Start", systemImage: "power") }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView()
            }
        }
        .foregroundStyle(.white)
    }
}
