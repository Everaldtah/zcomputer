import SwiftUI
import UniformTypeIdentifiers
import ZCore
import ZVM

/// New machine: ready-to-run Linux (cloud image + cloud-init), install from an ISO, or macOS (Apple silicon).
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

    @State private var source: Source = .cloudImage
    @State private var draft = MachineDraft()
    @State private var imageID = ImageCatalog.forHost.first?.id ?? ""
    @State private var user = "z"
    @State private var password = ""
    @State private var desktop = true
    @State private var isoURL: URL?
    @State private var isoWarning: String?
    @State private var restoreImageURL: URL?
    @State private var picking = false
    @State private var purpose: PickPurpose = .iso
    @State private var errorText: String?

    private var hostCPUs: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var hostMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

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
        .frame(width: 620, height: 680)
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
    }

    @ViewBuilder
    private var sourceSection: some View {
        switch source {
        case .cloudImage:
            Section("Image") {
                Picker("Distribution", selection: $imageID) {
                    ForEach(ImageCatalog.forHost) { image in
                        Text("\(image.name) · \(Format.bytes(image.downloadBytes)) download").tag(image.id)
                    }
                }
                TextField("User", text: $user)
                SecureField("Password", text: $password)
                Toggle("Install a desktop (Xfce) so the agent can use a GUI", isOn: $desktop)
                Text("cloud-init creates the user, installs the zguest agent from the app and, with a desktop, Xfce + "
                     + "xdotool on first boot (needs network; takes a few minutes).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .iso:
            Section("Installer") {
                HStack {
                    Text(isoURL?.lastPathComponent ?? "No image chosen").foregroundStyle(isoURL == nil ? Color.secondary : Color.primary)
                    Spacer()
                    Button("Choose ISO…") { pick(.iso) }
                }
                if let isoWarning {
                    Label(isoWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
        case .cloudImage: return !imageID.isEmpty && !user.isEmpty && !password.isEmpty
        case .iso: return isoURL != nil
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
            switch source {
            case .cloudImage:
                guard let image = ImageCatalog.image(id: imageID) else { throw ZError.notFound("image \(imageID)") }
                try model.machines.createFromCloudImage(draft, image: image, user: user, password: password,
                                                        desktop: desktop)
            case .iso:
                guard let isoURL else { throw ZError.invalidArgument("Choose an ISO first.") }
                try model.machines.createFromISO(draft, iso: isoURL)
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
