import SwiftUI
import ZCore
import ZVM

/// VM list (plus the Demo machine) and the selected machine's screen and controls.
struct MachinesView: View {
    @Environment(AppModel.self) private var model
    @State private var creating = false

    var body: some View {
        @Bindable var machines = model.machines
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $machines.selection) {
                    Section("Simulated") {
                        MachineRow(title: "Demo machine", subtitle: "Simulated Linux desktop", state: nil,
                                   systemImage: "sparkles.tv")
                            .tag(MachineID.demo)
                    }
                    Section("Virtual machines") {
                        ForEach(machines.specs) { spec in
                            MachineRow(title: spec.name,
                                       subtitle: "\(spec.guest == .macOS ? "macOS" : "Linux") · \(spec.cpuCount) CPU · "
                                           + "\(spec.memoryBytes >> 30) GB",
                                       state: machines.state(spec.id),
                                       systemImage: spec.guest == .macOS ? "apple.logo" : "terminal")
                                .tag(MachineID.vm(spec.id))
                        }
                        if machines.specs.isEmpty {
                            Text(machines.isSupported ? "No VMs yet" : "This Mac cannot run virtual machines")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                HStack {
                    Button {
                        creating = true
                    } label: {
                        Label("New Machine", systemImage: "plus")
                    }
                    .disabled(!machines.isSupported || machines.store == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)

            Group {
                switch machines.selection ?? .demo {
                case .demo:
                    DemoMachinePane()
                case .vm(let id):
                    if let spec = machines.spec(id) {
                        VMPane(spec: spec)
                    } else {
                        ContentUnavailableView("Machine not found", systemImage: "questionmark.square.dashed")
                    }
                }
            }
            .frame(minWidth: 520)
        }
        .sheet(isPresented: $creating) {
            CreateMachineSheet()
        }
        .navigationTitle("Machines")
        .onAppear { model.machines.reload() }
    }
}

private struct MachineRow: View {
    var title: String
    var subtitle: String
    var state: VMRunState?
    var systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let state {
                StatusDot(color: state.isActive ? (state == .paused ? .orange : .green) : (isError(state) ? .red : .gray))
            }
        }
    }

    private func isError(_ state: VMRunState) -> Bool {
        if case .error = state { return true }
        return false
    }
}

private struct DemoMachinePane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let machines = model.machines
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo machine").font(.title3.weight(.semibold))
                    Text("A simulated desktop for trying the agent. Nothing runs here; the screen is drawn by the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if machines.agentChoice == .demo {
                    Label("Agent's machine", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Use for the agent") { machines.setAgentChoice(.demo) }
                }
            }
            .padding(12)
            Divider()
            ControlledScreen(machineName: machines.demo.name) {
                DemoMachineDisplay()
            }
        }
    }
}

/// One VM: controls, job progress, screen, guest login.
private struct VMPane: View {
    @Environment(AppModel.self) private var model
    var spec: VMSpec
    @State private var confirmDelete = false

    var body: some View {
        let machines = model.machines
        let state = machines.state(spec.id)
        VStack(alignment: .leading, spacing: 0) {
            VMToolbar(spec: spec, state: state, confirmDelete: $confirmDelete)
            if let job = machines.jobs[spec.id] {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(job.title).font(.callout.weight(.medium))
                        Spacer()
                        Button("Cancel") { machines.cancelJob(spec.id) }.controlSize(.small)
                    }
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(job.detail).font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
            if let error = machines.errors[spec.id] {
                HStack {
                    MessageBanner(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                    Button { machines.dismissError(spec.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 8)
                }
            }
            Divider()
            ControlledScreen(machineName: spec.name) {
                if state.isActive, let controller = machines.existingController(for: spec.id) {
                    VMDisplayView(controller: controller)
                } else {
                    ContentUnavailableView {
                        Label(state == .stopped ? "Stopped" : state.description, systemImage: "power")
                    } description: {
                        Text(placeholderText)
                    } actions: {
                        Button("Start") { machines.start(spec.id) }
                            .disabled(machines.jobs[spec.id] != nil)
                    }
                }
            }
            GuestLoginEditor(id: spec.id)
        }
        .confirmationDialog("Delete \(spec.name)?", isPresented: $confirmDelete) {
            Button("Delete the VM and its disk", role: .destructive) { machines.delete(spec.id) }
        } message: {
            Text("The disk image and all files inside the VM are removed. This cannot be undone.")
        }
    }

    private var placeholderText: String {
        var parts: [String] = []
        switch spec.install {
        case .iso(let url): parts.append("Installer: \(url.lastPathComponent)\(spec.attachInstallMedia ? "" : " (detached)")")
        case .diskImage: parts.append("Ready-to-run Linux image")
        case .macOSRestoreImage: parts.append("macOS (installed from Apple's restore image)")
        case .none: break
        }
        parts.append("\(spec.cpuCount) CPUs, \(spec.memoryBytes >> 30) GB memory, \(spec.diskBytes >> 30) GB disk, "
                     + "\(spec.display.width)×\(spec.display.height) display")
        if !spec.notes.isEmpty { parts.append(spec.notes) }
        return parts.joined(separator: "\n")
    }
}

private struct VMToolbar: View {
    @Environment(AppModel.self) private var model
    var spec: VMSpec
    var state: VMRunState
    @Binding var confirmDelete: Bool

    var body: some View {
        let machines = model.machines
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).font(.title3.weight(.semibold))
                Text(state.description.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state.isActive {
                if state == .paused {
                    Button { machines.resume(spec.id) } label: { Label("Resume", systemImage: "play.fill") }
                } else {
                    Button { machines.pause(spec.id) } label: { Label("Pause", systemImage: "pause.fill") }
                }
                Button { machines.stop(spec.id, force: false) } label: { Label("Shut Down", systemImage: "power") }
                Button(role: .destructive) { machines.stop(spec.id, force: true) } label: {
                    Label("Force Stop", systemImage: "bolt.slash")
                }
            } else {
                Button { machines.start(spec.id) } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(machines.jobs[spec.id] != nil)
            }
            Menu {
                if machines.agentChoice != .vm(spec.id) {
                    Button("Use for the agent") { machines.setAgentChoice(.vm(spec.id)) }
                }
                if spec.guest == .linux {
                    Button("Install the guest agent (serial console)") { machines.provisionGuestAgent(spec.id) }
                        .disabled(!state.isActive)
                }
                if case .iso = spec.install, spec.attachInstallMedia {
                    Button("Installation finished: detach the ISO") { machines.finishInstallation(spec.id) }
                        .disabled(state.isActive)
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
                    .disabled(state.isActive)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
        .padding(12)
    }
}

/// The guest login used by the serial-console shell fallback and the guest-agent installer (kept in the Keychain).
private struct GuestLoginEditor: View {
    @Environment(AppModel.self) private var model
    var id: UUID
    @State private var user = ""
    @State private var password = ""
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Guest login", isExpanded: $expanded) {
            HStack {
                TextField("User", text: $user).frame(maxWidth: 160)
                SecureField("Password", text: $password).frame(maxWidth: 200)
                Button("Save") {
                    let trimmed = user.trimmingCharacters(in: .whitespaces)
                    model.machines.setCredentials(trimmed.isEmpty ? nil : VMSurface.Credentials(user: trimmed, password: password),
                                                  for: id)
                }
                Text("Used by the serial console when the guest agent is not running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            if let creds = model.machines.credentials(for: id) {
                user = creds.user
                password = creds.password ?? ""
            }
        }
    }
}
