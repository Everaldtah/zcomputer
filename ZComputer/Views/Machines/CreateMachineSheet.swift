import SwiftUI
import UniformTypeIdentifiers
import ZCore
import ZVM

/// New machine: ready-to-run Linux (a catalogue cloud image + cloud-init presets), install from an ISO (a catalogue
/// installer or your own file), or macOS (Apple silicon).
struct CreateMachineSheet: View {
    enum Source: String, CaseIterable, Identifiable {
        case cloudImage = "Ready-to-run Linux"
        case iso = "Install from ISO"
        case macOS = "macOS"
        var id: String { rawValue }
    }

    enum PickPurpose { case iso, restoreImage, sharedFolder }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var source: Source
    @State private var draft = MachineDraft()
    @State private var imageID: String
    @State private var user = "z"
    @State private var password = ""
    @State private var desktop = true
    @State private var devTools = false
    /// A catalogue ISO id, or "" for the user's own file.
    @State private var catalogISOID: String
    @State private var isoURL: URL?
    @State private var isoWarning: String?
    @State private var restoreImageURL: URL?
    @State private var picking = false
    @State private var purpose: PickPurpose = .iso
    @State private var errorText: String?

    init(request: CreateMachineRequest) {
        let defaultCloud = ImageCatalog.recommended(.desktop)?.id
            ?? ImageCatalog.images(for: .host, group: .cloud).first?.id ?? ""
        var initialDraft = MachineDraft()
        switch request.start {
        case .blank:
            _source = State(initialValue: .cloudImage)
            _imageID = State(initialValue: defaultCloud)
            _catalogISOID = State(initialValue: "")
        case .cloudImage(let id):
            _source = State(initialValue: .cloudImage)
            _imageID = State(initialValue: id)
            _catalogISOID = State(initialValue: "")
            if let image = ImageCatalog.image(id: id) { initialDraft.name = image.name }
        case .catalogISO(let id):
            _source = State(initialValue: .iso)
            _imageID = State(initialValue: defaultCloud)
            _catalogISOID = State(initialValue: id)
            if let image = ImageCatalog.image(id: id) { initialDraft.name = image.name }
        }
        _draft = State(initialValue: initialDraft)
    }

    private var hostCPUs: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var hostMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }
    private var host: HostProfile { model.imageLibrary.host }
    private var cloudImages: [CatalogImage] { model.imageLibrary.hostImages(.cloud) }
    private var isoImages: [CatalogImage] { model.imageLibrary.hostImages(.iso) }
    private var selectedCloudImage: CatalogImage? { cloudImages.first { $0.id == imageID } }
    private var selectedISO: CatalogImage? { catalogISOID.isEmpty ? nil : isoImages.first { $0.id == catalogISOID } }
    private var desktopSupported: Bool { selectedCloudImage.map { DesktopPreset.xfceX11.isSupported(on: $0.family) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Machine").font(.title2.weight(.semibold)).padding([.top, .horizontal], 20)
            Form {
                Picker("Source", selection: $source) {
                    ForEach(availableSources) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Section("Machine") {
                    TextField("Name", text: $draft.name)
                    Stepper("CPUs: \(draft.cpuCount)", value: $draft.cpuCount, in: 1...max(1, hostCPUs))
                    Stepper("Memory: \(draft.memoryGB) GB", value: $draft.memoryGB, in: 2...max(2, hostMemoryGB - 2))
                    Stepper("Disk: \(draft.diskGB) GB (sparse)", value: $draft.diskGB, in: 8...2048, step: 8)
                    HStack {
                        Text("Display")
                        TextField("Width", value: $draft.displayWidth, format: .number).frame(width: 70)
                        Text("×")
                        TextField("Height", value: $draft.displayHeight, format: .number).frame(width: 70)
                    }
                    Toggle("Headless (no window; the agent still sees the screen)", isOn: $draft.headless)
                    Toggle("Sound output", isOn: $draft.audio)
                    if source != .macOS && GuestArchitecture.host == .arm64 {
                        Toggle("Share Rosetta (run x86_64 Linux binaries)", isOn: $draft.rosetta)
                    }
                }

                sourceSection

                Section("Shared folders (virtio-fs)") {
                    ForEach(draft.sharedFolders, id: \.self) { url in
                        HStack {
                            Label(url.path, systemImage: "folder")
                            Spacer()
                            Button { draft.sharedFolders.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add Folder…") { pick(.sharedFolder) }
                }
            }
            .formStyle(.grouped)

            if let errorText {
                MessageBanner(text: errorText, systemImage: "exclamationmark.triangle.fill", tint: .red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
        .fileImporter(isPresented: $picking, allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            switch purpose {
            case .iso:
                isoURL = url
                isoWarning = model.machines.isoWarning(for: url)
                if draft.name == "Linux VM" { draft.name = url.deletingPathExtension().lastPathComponent }
            case .restoreImage:
                restoreImageURL = url
            case .sharedFolder:
                if !draft.sharedFolders.contains(url) { draft.sharedFolders.append(url) }
            }
        }
        .onChange(of: source) {
            if source == .macOS {
                draft.name = "macOS VM"
                draft.memoryGB = max(draft.memoryGB, 8)
                draft.diskGB = max(draft.diskGB, 80)
                draft.cpuCount = max(draft.cpuCount, min(4, hostCPUs))
            } else if draft.name == "macOS VM" {
                draft.name = "Linux VM"
            }
        }
        .onChange(of: imageID) {
            if !desktopSupported { desktop = false }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch source {
        case .cloudImage:
            Section("Image") {
                Picker("Distribution", selection: $imageID) {
                    ForEach(cloudImages) { image in
                        Text(cloudLabel(image)).tag(image.id)
                    }
                }
                if let image = selectedCloudImage {
                    CatalogNotes(image: image, host: host)
                }
                TextField("User", text: $user)
                if !CloudInitConfig.isValidUserName(user) {
                    Text("Lowercase letters, digits, - and _ (starting with a letter).").font(.caption).foregroundStyle(.red)
                }
                SecureField("Password", text: $password)
                Toggle("Install a desktop (Xfce on X11, auto-login) so the agent can use a GUI", isOn: $desktop)
                    .disabled(!desktopSupported)
                Toggle("Install developer tools (git, build tools, Python, Node.js, tmux, ripgrep)", isOn: $devTools)
                Text("cloud-init creates the user and installs the guest agent first; the desktop and tools follow on "
                     + "first boot (network needed, a few minutes). The machine boots by itself once its disk is ready, "
                     + "and the progress shows on its page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .iso:
            Section("Installer") {
                Picker("Image", selection: $catalogISOID) {
                    Text("My own ISO file…").tag("")
                    ForEach(isoImages) { image in
                        Text("\(image.name) · \(Format.bytes(image.sizeBytes))\(image.experimental ? " · experimental" : "")")
                            .tag(image.id)
                    }
                }
                if let image = selectedISO {
                    CatalogNotes(image: image, host: host)
                    Text("Downloaded into the image cache and checked against its \(image.checksum.algo.displayName) "
                         + "checksum; press Start once it is ready.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Text(isoURL?.lastPathComponent ?? "No image chosen")
                            .foregroundStyle(isoURL == nil ? Color.secondary : Color.primary)
                        Spacer()
                        Button("Choose ISO…") { pick(.iso) }
                    }
                    if let isoWarning {
                        Label(isoWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                Text(GuestArchitecture.host == .arm64
                     ? "Apple silicon boots arm64 (aarch64) UEFI images only."
                     : "This Mac boots x86_64 UEFI images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .macOS:
            Section("Restore image") {
                HStack {
                    Text(restoreImageURL?.lastPathComponent ?? "Latest macOS from Apple (downloads several GB)")
                    Spacer()
                    Button("Choose .ipsw…") { pick(.restoreImage) }
                    if restoreImageURL != nil { Button("Use latest") { restoreImageURL = nil } }
                }
                Text("At most two macOS VMs can run at the same time (macOS licence).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func cloudLabel(_ image: CatalogImage) -> String {
        var text = "\(image.name) · \(Format.bytes(image.sizeBytes))"
        if let role = image.recommended { text += " · recommended (\(role.rawValue))" }
        if image.isAdvanced { text += " · advanced" }
        return text
    }

    private var availableSources: [Source] {
        #if arch(arm64)
        return Source.allCases
        #else
        return [.cloudImage, .iso]
        #endif
    }

    private var allowedTypes: [UTType] {
        switch purpose {
        case .iso:
            return [UTType(filenameExtension: "iso"), UTType(filenameExtension: "img"), UTType.diskImage].compactMap { $0 }
        case .restoreImage:
            return [UTType(filenameExtension: "ipsw") ?? .data]
        case .sharedFolder:
            return [.folder]
        }
    }

    private var canCreate: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch source {
        case .cloudImage: return selectedCloudImage != nil && CloudInitConfig.isValidUserName(user) && !password.isEmpty
        case .iso: return catalogISOID.isEmpty ? isoURL != nil : selectedISO != nil
        case .macOS: return true
        }
    }

    private func pick(_ purpose: PickPurpose) {
        self.purpose = purpose
        picking = true
    }

    private func create() {
        errorText = nil
        do {
            let library = model.imageLibrary
            switch source {
            case .cloudImage:
                guard let image = selectedCloudImage else { throw ZError.notFound("image \(imageID)") }
                try library.createCloudMachine(spec: draft.makeSpec(guest: .linux), image: image, user: user,
                                               password: password, desktop: desktop && desktopSupported ? .xfceX11 : .none,
                                               dev: devTools ? .standard : .none, templateName: "Ready-to-run Linux")
            case .iso:
                if let image = selectedISO {
                    try library.createISOMachine(spec: draft.makeSpec(guest: .linux), image: image,
                                                 templateName: "Installer", boot: false)
                } else {
                    guard let isoURL else { throw ZError.invalidArgument("Choose an ISO first.") }
                    try model.machines.createFromISO(draft, iso: isoURL)
                }
            case .macOS:
                #if arch(arm64)
                try model.machines.createMacOS(draft, restoreImage: restoreImageURL)
                #else
                throw ZError.unsupported("macOS guests need a Mac with Apple silicon.")
                #endif
            }
            dismiss()
        } catch {
            errorText = Format.describe(error)
        }
    }
}

/// The research notes and the warnings for one catalogue image (Wayland, experimental, advanced, Intel nopku).
private struct CatalogNotes: View {
    var image: CatalogImage
    var host: HostProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if image.experimental {
                Label("Experimental: no partition table (El Torito only); booting under Virtualization.framework is unverified.",
                      systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let desktop = image.desktop, desktop.isWayland {
                Label("\(desktop.displayName): the agent's xdotool and screenshots need an X11 session.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if image.isAdvanced {
                Label("Advanced: OpenRC instead of systemd; the guest agent setup is unverified.",
                      systemImage: "wrench.and.screwdriver").foregroundStyle(.purple)
            }
            if image.needsNopku(on: host) {
                Label("This Intel Mac runs macOS \(host.osVersion.description): this kernel (6.12+) needs macOS "
                      + "\(image.intelMinMacOS ?? "15.5") or the `nopku` kernel argument (lima#3334).",
                      systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(image.notes, id: \.self) { note in
                Text("• " + note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }
}
