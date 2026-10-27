import SwiftUI
import ZCore
import ZProviders

/// Settings ▸ Providers over ZProviders' `ProviderCatalog`: keys (Keychain), base-URL overrides and placeholder values,
/// a Test button (`KeyTester`), the model list (`listModels`) and custom OpenAI-compatible providers.
struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ProviderID?
    @State private var addingCustom = false
    @State private var keyed: Set<ProviderID> = []

    var body: some View {
        let catalog = model.catalog
        let customIDs = model.customProviderIDs
        HSplitView {
            List(selection: $selection) {
                Section("Free and freemium") {
                    rows(catalog.all.filter { $0.offersFreeUse && !customIDs.contains($0.id) })
                }
                Section("Paid") {
                    rows(catalog.all.filter { $0.kind == .paid && !customIDs.contains($0.id) && $0.id != ProviderID("custom") })
                }
                Section("On your Mac or network") {
                    rows(catalog.all.filter { $0.isLocal && !customIDs.contains($0.id) })
                }
                Section("Custom") {
                    rows(catalog.all.filter { customIDs.contains($0.id) })
                    Button("Add OpenAI-compatible provider…") { addingCustom = true }
                        .buttonStyle(.link)
                }
            }
            .frame(minWidth: 230, idealWidth: 260, maxWidth: 330)

            Group {
                if let id = selection, let provider = catalog.provider(id) {
                    ProviderDetail(provider: provider, isCustom: customIDs.contains(id)) { refreshKeys() }
                        .id(id)
                } else {
                    ContentUnavailableView("Choose a provider", systemImage: "cloud",
                                           description: Text("Providers marked Free have a free tier. Keys are kept in your Keychain."))
                }
            }
            .frame(minWidth: 420)
        }
        .sheet(isPresented: $addingCustom) {
            CustomProviderSheet { id in selection = id }
        }
        .onAppear(perform: refreshKeys)
    }

    private func rows(_ providers: [ProviderDescriptor]) -> some View {
        ForEach(providers) { provider in
            HStack {
                Text(provider.name).lineLimit(1)
                Spacer()
                if keyed.contains(provider.id) {
                    Image(systemName: "key.fill").foregroundStyle(.green).help("Key saved")
                }
                KindBadge(kind: provider.kind)
            }
            .tag(provider.id)
        }
    }

    private func refreshKeys() {
        keyed = Set(model.catalog.all.map(\.id).filter {
            model.keyStore.hasSecret(account: KeychainKeyStore.keyAccount($0))
        })
    }
}

struct KindBadge: View {
    var kind: ProviderKind

    var body: some View {
        let (text, color): (String, Color) = {
            switch kind {
            case .free: return ("Free", .green)
            case .freemium: return ("Free tier", .teal)
            case .paid: return ("Paid", .secondary)
            case .local: return ("Local", .blue)
            }
        }()
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

private struct ProviderDetail: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderDescriptor
    let isCustom: Bool
    var onKeysChanged: () -> Void

    @State private var keyInput = ""
    @State private var hasKey = false
    @State private var baseURLInput = ""
    @State private var modelID = ""
    @State private var listed: [ModelInfo] = []
    @State private var busy = false
    @State private var testResult: KeyTestResult?
    @State private var message: String?
    @AppStorage(SettingsKey.agentProvider) private var agentProvider = ""
    @AppStorage(SettingsKey.agentModel) private var agentModel = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(provider.name).font(.title3.weight(.semibold))
                    KindBadge(kind: provider.kind)
                    Spacer()
                    if let docs = provider.docsURL.flatMap(URL.init(string:)) { Link("Docs", destination: docs) }
                }
                if let tier = provider.freeTier, tier.available {
                    Text(tier.limits ?? "Free tier available.").font(.callout)
                    if let notes = tier.notes { Text(notes).font(.caption).foregroundStyle(.secondary) }
                }
                Text("API: \(provider.apiStyle.rawValue) · \(provider.baseURL.isEmpty ? "no default URL" : provider.baseURL)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }

            if provider.authHeader != .noAuth {
                Section("API key") {
                    SecureField(hasKey ? "Replace the saved key" : "Paste your key", text: $keyInput)
                    HStack {
                        Button("Save Key") { saveKey(keyInput) }
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if hasKey { Button("Remove Key", role: .destructive) { saveKey(nil) } }
                        Spacer()
                        if let keyURL = provider.keyURL.flatMap(URL.init(string:)) { Link("Get a key", destination: keyURL) }
                    }
                    Text(hasKey ? "A key is saved in the Keychain." : (provider.requiresAPIKey ? "No key saved." : "A key is optional."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Base URL") {
                TextField(baseURLPrompt, text: $baseURLInput)
                    .font(.callout.monospaced())
                HStack {
                    Button("Save") { saveBaseURL() }
                    Text(baseURLHint).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Model") {
                Picker("Model", selection: $modelID) {
                    Text("Default (\(provider.defaultModel.isEmpty ? "none" : provider.defaultModel))").tag("")
                    ForEach(modelOptions, id: \.id) { info in
                        Text(info.free ? "\(info.displayName) (free)" : info.displayName).tag(info.id)
                    }
                }
                TextField("Or type a model id", text: $modelID).font(.callout.monospaced())
                HStack {
                    Button("Fetch Models") { fetchModels() }
                    Button("Test") { test() }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button("Use for the Agent") {
                        agentProvider = provider.id.rawValue
                        agentModel = effectiveModel
                    }
                    .disabled(effectiveModel.isEmpty)
                }
                if let testResult {
                    Label(testResult.message + (testResult.ok ? String(format: " (%.1f s)", testResult.latency) : ""),
                          systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testResult.ok ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }

            if isCustom {
                Section {
                    Button("Remove This Provider", role: .destructive) {
                        Task {
                            try? await model.removeCustomProvider(provider.id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var effectiveModel: String { modelID.isEmpty ? provider.defaultModel : modelID }

    private var modelOptions: [ModelInfo] {
        var seen = Set<String>()
        return (provider.modelInfos + listed).filter { seen.insert($0.id).inserted }
    }

    private var baseURLPrompt: String {
        let names = provider.baseURLPlaceholders
        if !names.isEmpty { return names.map { "\($0)=…" }.joined(separator: "&") + "  or a full https:// URL" }
        return provider.baseURL.isEmpty ? "https://host/v1" : "Default: \(provider.baseURL)"
    }

    private var baseURLHint: String {
        let names = provider.baseURLPlaceholders
        if !names.isEmpty { return "Needs \(names.map { "{\($0)}" }.joined(separator: ", ")) in \(provider.baseURL)." }
        return "Empty = the default URL. A full http(s) URL replaces it (gateways, proxies, other ports)."
    }

    private func load() async {
        hasKey = await model.keyStore.apiKey(for: provider.id) != nil
        baseURLInput = await model.keyStore.baseURLOverride(for: provider.id)?.absoluteString ?? ""
        if agentProvider == provider.id.rawValue { modelID = agentModel }
    }

    private func saveKey(_ key: String?) {
        Task {
            do {
                try await model.keyStore.setAPIKey(key, for: provider.id)
                keyInput = ""
                hasKey = key != nil
                message = key == nil ? "Key removed." : "Key saved."
                onKeysChanged()
            } catch {
                message = Format.describe(error)
            }
        }
    }

    private func saveBaseURL() {
        let text = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        if text.isEmpty {
            url = nil
        } else if let parsed = URL(string: text) {
            url = parsed
        } else {
            message = "That is not a valid URL or name=value list."
            return
        }
        Task {
            do {
                try await model.keyStore.setBaseURLOverride(url, for: provider.id)
                _ = try ProviderClientFactory.resolveBaseURL(template: provider.baseURL, override: url,
                                                             providerName: provider.name)
                message = "Base URL saved."
            } catch {
                message = Format.describe(error)
            }
        }
    }

    private func test() {
        busy = true
        testResult = nil
        let provider = self.provider
        let keyStore = model.keyStore
        let chosen = modelID.isEmpty ? nil : modelID
        Task {
            testResult = await KeyTester.test(provider: provider, model: chosen, keyStore: keyStore)
            busy = false
        }
    }

    private func fetchModels() {
        busy = true
        message = nil
        let provider = self.provider
        let keyStore = model.keyStore
        let probe = effectiveModel.isEmpty ? "probe" : effectiveModel
        Task {
            do {
                let client = try await ProviderClientFactory.makeClient(provider: provider, model: probe, keyStore: keyStore)
                listed = try await client.listModels()
                message = "\(listed.count) models."
            } catch {
                message = Format.describe(error)
            }
            busy = false
        }
    }
}

/// Adds a user-defined OpenAI-compatible provider (any /v1 server).
private struct CustomProviderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onAdded: (ProviderID) -> Void
    @State private var name = ""
    @State private var baseURL = "https://"
    @State private var requiresKey = true
    @State private var models = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an OpenAI-compatible provider").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Base URL (ending in /v1)", text: $baseURL)
                Toggle("Needs an API key", isOn: $requiresKey)
                TextField("Model ids (comma separated)", text: $models)
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: baseURL)?.host == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let id = ProviderID("custom-" + slug)
        let ids = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let descriptor = ProviderDescriptor.custom(id: id, name: name.trimmingCharacters(in: .whitespaces),
                                                   baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                                                   requiresKey: requiresKey,
                                                   models: ids.map { ModelDescriptor(id: $0, tools: true) })
        Task {
            do {
                try await model.saveCustomProvider(descriptor)
                onAdded(id)
                dismiss()
            } catch {
                self.error = Format.describe(error)
            }
        }
    }
}
