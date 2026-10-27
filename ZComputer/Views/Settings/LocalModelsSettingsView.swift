import SwiftUI
import ZCore
import ZLocal

/// Settings ▸ Local models: discovered servers (Ollama, LM Studio, llama.cpp, Jan, vLLM, KoboldCpp), the curated
/// in-app MLX catalogue with downloads, and Apple's on-device model.
struct LocalModelsSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.showExperimentalModels) private var showExperimental = false
    @AppStorage(SettingsKey.agentProvider) private var agentProvider = ""
    @AppStorage(SettingsKey.agentModel) private var agentModel = ""
    @State private var endpoint = ""

    var body: some View {
        let local = model.localModels
        Form {
            Section {
                HostSummary(host: local.host, diskUsage: local.diskUsage)
            }

            Section {
                if local.servers.isEmpty {
                    Text(local.isScanning ? "Scanning…" : "No local server found on this Mac. Start Ollama, LM Studio or llama-server, then Rescan.")
                        .foregroundStyle(.secondary)
                }
                ForEach(local.servers) { server in
                    ServerRow(server: server) { ref in
                        agentProvider = ref.provider.rawValue
                        agentModel = ref.model
                    }
                }
                HStack {
                    TextField("Another server (host:port)", text: $endpoint)
                    Button("Add") {
                        let text = endpoint
                        endpoint = ""
                        Task { await model.localModels.addEndpoint(text) }
                    }
                    .disabled(endpoint.isEmpty)
                }
            } header: {
                HStack {
                    Text("Servers")
                    Spacer()
                    if local.isScanning { ProgressView().controlSize(.small) }
                    Button("Rescan") { Task { await model.localModels.rescan() } }
                        .disabled(local.isScanning)
                }
            }

            Section {
                if !LocalModelsModel.hasMLXRuntime {
                    Label("This build has no MLX runtime (built without ZC_MLX): downloads work, running them needs an MLX build.",
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
                Text("In-app models (MLX, Apple silicon)")
            } footer: {
                Text("Sizes are downloads; memory needs are a heuristic that leaves room for a running VM.")
            }

            Section("Embedding models (for the library)") {
                ForEach(local.embedders) { spec in
                    CatalogueRow(spec: spec, onUse: nil)
                }
            }

            Section("Apple on-device model") {
                AppleModelRow {
                    agentProvider = AppProviders.apple.rawValue
                    agentModel = AppProviders.appleModelID
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.localModels.refreshInstalled()
            await model.localModels.rescan()
        }
        .alert("Local models", isPresented: Binding(get: { model.localModels.lastError != nil },
                                                    set: { if !$0 { model.localModels.lastError = nil } })) {
            Button("OK") { model.localModels.lastError = nil }
        } message: {
            Text(model.localModels.lastError ?? "")
        }
    }
}

private struct HostSummary: View {
    var host: HostCapabilities
    var diskUsage: Int64

    var body: some View {
        HStack(spacing: 16) {
            Label("\(host.ramGB) GB memory", systemImage: "memorychip")
            Label(host.isAppleSilicon ? "Apple silicon" : "Intel (no MLX)", systemImage: "cpu")
            if let free = host.availableDiskBytes { Label("\(Format.bytes(free)) free", systemImage: "internaldrive") }
            Label("Models use \(Format.bytes(diskUsage))", systemImage: "shippingbox")
        }
        .font(.callout)
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
                    Button("Use for the Agent") { onUse(ModelRef(provider: server.providerID, model: info.id)) }
                        .buttonStyle(.link)
                }
            }
        } label: {
            HStack {
                StatusDot(color: server.reachable ? (server.loading ? .orange : .green) : .gray)
                Text(server.name).font(.body.weight(.medium))
                Text(server.baseURL.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if server.requiresAuth {
                    Text("needs a token (Settings ▸ Providers)").font(.caption).foregroundStyle(.orange)
                } else if server.loading {
                    Text("loading a model").font(.caption).foregroundStyle(.orange)
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
    var onUse: (() -> Void)?

    var body: some View {
        let local = model.localModels
        let issues = local.fitIssues(spec)
        let installed = local.isInstalled(spec.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(spec.name).font(.body.weight(.medium))
                if spec.vision { Badge(text: "vision") }
                if spec.tools { Badge(text: "tools") }
                if spec.experimental { Badge(text: "experimental") }
                Spacer()
                Text("\(Format.gigabytes(spec.sizeGB)) · \(spec.minRAMGB) GB RAM").font(.caption).foregroundStyle(.secondary)
                actions(installed: installed)
            }
            Text(spec.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            if !issues.isEmpty {
                Label(issues.map(\.description).joined(separator: "; "), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            switch local.downloads[spec.id] {
            case .planning?:
                ProgressView("Listing files…").controlSize(.small)
            case .downloading(let progress)?:
                ProgressView(value: progress.fraction) {
                    Text("\(progress.currentFile) (\(progress.fileIndex)/\(progress.fileCount))").font(.caption)
                } currentValueLabel: {
                    Text("\(Format.bytes(progress.completedBytes)) of \(Format.bytes(progress.totalBytes))").font(.caption2)
                }
            case .finishing?:
                ProgressView("Checking files…").controlSize(.small)
            case .failed(let message)?:
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { model.localModels.clearFailure(spec.id) }.buttonStyle(.link)
                }
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actions(installed: Bool) -> some View {
        let local = model.localModels
        if local.downloads[spec.id] != nil, !isFailed {
            Button("Cancel") { local.cancelDownload(spec.id) }
        } else if installed {
            if let onUse, LocalModelsModel.hasMLXRuntime { Button("Use for the Agent", action: onUse) }
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
            if available { Button("Use for the Agent", action: onUse) }
        }
    }

    private var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return FoundationModelsClient.unavailableReason == nil }
        #endif
        return false
    }

    private var status: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return FoundationModelsClient.unavailableReason ?? "Available: text only, 4K context, runs on this Mac."
        }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }
}

struct Badge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
