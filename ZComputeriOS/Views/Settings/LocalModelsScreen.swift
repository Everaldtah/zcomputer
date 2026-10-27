import SwiftUI
import ZCore
import ZLocal

/// Settings ▸ Local models: model servers the user added by address (Ollama / LM Studio on their Mac over Tailscale or
/// the LAN), the curated MLX catalogue with downloads and fit warnings for this device's memory, and Apple's model.
struct LocalModelsScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.showExperimentalModels) private var showExperimental = false
    @AppStorage(SettingsKey.agentProvider) private var agentProvider = ""
    @AppStorage(SettingsKey.agentModel) private var agentModel = ""
    @State private var endpoint = ""

    var body: some View {
        let local = model.localModels
        Form {
            Section {
                LabeledContent("Memory", value: "\(local.host.ramGB) GB")
                LabeledContent("The app can use now", value: DeviceInfo.availableMemoryBytes > 0
                               ? Format.bytes(DeviceInfo.availableMemoryBytes) : "unknown")
                if let free = local.host.availableDiskBytes { LabeledContent("Free storage", value: Format.bytes(free)) }
                LabeledContent("Downloaded models", value: Format.bytes(local.diskUsage))
            } header: {
                Text("This device")
            }

            Section {
                ForEach(model.remoteHosts, id: \.self) { host in
                    Text(host).font(.callout.monospaced())
                }
                .onDelete { offsets in
                    let hosts = offsets.map { model.remoteHosts[$0] }
                    Task { for host in hosts { await model.removeRemoteHost(host) } }
                }
                HStack {
                    TextField("host:port, e.g. 100.64.0.2:11434", text: $endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(addHost)
                    Button("Add", action: addHost).disabled(endpoint.isEmpty)
                }
                ForEach(local.servers) { server in
                    ServerRow(server: server) { ref in
                        agentProvider = ref.provider.rawValue
                        agentModel = ref.model
                    }
                }
            } header: {
                HStack {
                    Text("Your model servers")
                    Spacer()
                    if local.isScanning { ProgressView() }
                    Button("Rescan") { Task { await model.localModels.rescan() } }
                        .font(.caption)
                        .disabled(local.isScanning)
                }
            } footer: {
                Text("Run Ollama or LM Studio on your Mac or PC and enter its address (Tailscale works from anywhere). "
                     + "Servers are never scanned on the network automatically.")
            }

            Section {
                if !LocalModelsModel.hasMLXRuntime {
                    Label("This build has no MLX runtime: downloads work, running them needs an MLX build.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show experimental models", isOn: $showExperimental)
                ForEach(local.catalogue(includeExperimental: showExperimental)) { spec in
                    CatalogueRow(spec: spec) {
                        agentProvider = AppProviders.mlx.rawValue
                        agentModel = spec.id
                    }
                }
            } header: {
                Text("On-device models (MLX)")
            } footer: {
                Text("Sizes are downloads. A phone keeps the whole model in memory while it runs: small models "
                     + "(1–4B, 4-bit) suit iPhones, larger ones need an iPad with 16 GB.")
            }

            Section("Apple on-device model") {
                AppleModelRow {
                    agentProvider = AppProviders.apple.rawValue
                    agentModel = AppProviders.appleModelID
                }
            }
        }
        .navigationTitle("Local models")
        .task {
            await model.localModels.refreshInstalled()
        }
        .alert("Local models", isPresented: Binding(get: { model.localModels.lastError != nil },
                                                    set: { if !$0 { model.localModels.lastError = nil } })) {
            Button("OK") { model.localModels.lastError = nil }
        } message: {
            Text(model.localModels.lastError ?? "")
        }
    }

    private func addHost() {
        let text = endpoint
        endpoint = ""
        Task { await model.addRemoteHost(text) }
    }
}

private struct ServerRow: View {
    var server: LocalServer
    var onUse: (ModelRef) -> Void

    var body: some View {
        DisclosureGroup {
            ForEach(server.models) { info in
                HStack {
                    Text(info.displayName).font(.callout)
                    if info.capabilities.vision { Badge(text: "vision") }
                    if info.capabilities.tools { Badge(text: "tools") }
                    Spacer()
                    Button("Use") { onUse(ModelRef(provider: server.providerID, model: info.id)) }
                        .buttonStyle(.borderless)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    StatusDot(color: server.reachable ? (server.loading ? .orange : .green) : .gray)
                    Text(server.name).font(.body.weight(.medium))
                }
                Text(server.baseURL.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                if server.requiresAuth {
                    Text("Needs a token (Settings ▸ Providers)").font(.caption).foregroundStyle(.orange)
                } else if server.loading {
                    Text("Loading a model").font(.caption).foregroundStyle(.orange)
                } else {
                    Text("\(server.models.count) models · \(server.latencyMs) ms").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CatalogueRow: View {
    @Environment(AppModel.self) private var model
    var spec: LocalModelSpec
    var onUse: () -> Void

    var body: some View {
        let local = model.localModels
        let installed = local.isInstalled(spec.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.name).font(.body.weight(.medium))
                if spec.vision { Badge(text: "vision") }
                if spec.tools { Badge(text: "tools") }
                if spec.experimental { Badge(text: "experimental") }
            }
            Text("\(Format.gigabytes(spec.sizeGB)) download · \(spec.minRAMGB) GB RAM suggested")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            progress
            HStack {
                actions(installed: installed)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    /// Fit warnings in iPhone terms (ZLocal's messages talk about Macs).
    private var warnings: [String] {
        var out: [String] = []
        for issue in model.localModels.fitIssues(spec) {
            switch issue {
            case .notAppleSilicon:
                out.append("MLX needs a real device with an Apple GPU (not this simulator).")
            case .insufficientRAM(let need, let have):
                out.append("Suggested for \(need) GB of memory; this device has \(have) GB.")
            case .insufficientDisk(let need, let have):
                out.append("Needs \(Format.bytes(need)) of free storage (\(Format.bytes(have)) free).")
            }
        }
        if let memory = DeviceInfo.memoryWarning(forModelBytes: spec.sizeBytes) { out.append(memory) }
        return out
    }

    @ViewBuilder
    private var progress: some View {
        switch model.localModels.downloads[spec.id] {
        case .planning?:
            ProgressView("Listing files…")
        case .downloading(let progress)?:
            ProgressView(value: progress.fraction) {
                Text("\(progress.currentFile) (\(progress.fileIndex)/\(progress.fileCount))").font(.caption).lineLimit(1)
            } currentValueLabel: {
                Text("\(Format.bytes(progress.completedBytes)) of \(Format.bytes(progress.totalBytes))").font(.caption2)
            }
        case .finishing?:
            ProgressView("Checking files…")
        case .failed(let message)?:
            HStack {
                Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Dismiss") { model.localModels.clearFailure(spec.id) }
            }
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actions(installed: Bool) -> some View {
        let local = model.localModels
        if local.downloads[spec.id] != nil, !isFailed {
            Button("Cancel") { local.cancelDownload(spec.id) }
        } else if installed {
            if LocalModelsModel.hasMLXRuntime { Button("Use for the Agent", action: onUse) }
            Spacer()
            Button("Delete", role: .destructive) { Task { await model.localModels.delete(spec.id) } }
        } else {
            Button("Download") { local.download(spec) }
        }
    }

    private var isFailed: Bool {
        if case .failed? = model.localModels.downloads[spec.id] { return true }
        return false
    }
}

private struct AppleModelRow: View {
    var onUse: () -> Void

    var body: some View {
        HStack {
            Text(status).font(.callout)
            Spacer()
            if available { Button("Use", action: onUse).buttonStyle(.borderless) }
        }
    }

    private var available: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) { return FoundationModelsClient.unavailableReason == nil }
        #endif
        return false
    }

    private var status: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelsClient.unavailableReason ?? "Available: text only, 4K context, runs on this device."
        }
        #endif
        return "Needs iOS 26 with Apple Intelligence."
    }
}
