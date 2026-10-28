import SwiftUI
import ZCore
import ZProviders

/// Settings ▸ Providers: the ZProviders catalogue as a grid of cards with Free badges, grouped like the Mac app.
struct ProvidersScreen: View {
    @Environment(AppModel.self) private var model
    @State private var keyed: Set<ProviderID> = []
    @State private var addingCustom = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        let catalog = model.catalog
        let customIDs = model.customProviderIDs
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Free and freemium", catalog.all.filter { $0.offersFreeUse && !customIDs.contains($0.id) })
                group("Paid", catalog.all.filter {
                    $0.kind == .paid && !customIDs.contains($0.id) && $0.id != ProviderID("custom")
                })
                group("Your servers", catalog.all.filter { $0.isLocal && !customIDs.contains($0.id) })
                group("Custom", catalog.all.filter { customIDs.contains($0.id) })
                Button {
                    addingCustom = true
                } label: {
                    Label("Add OpenAI-compatible provider", systemImage: "plus.circle")
                }
                Text("Keys are kept in this device's Keychain and sent only to the provider they belong to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .navigationTitle("Providers")
        .navigationDestination(for: ProviderID.self) { id in
            if let provider = model.catalog.provider(id) {
                ProviderDetail(provider: provider, isCustom: model.customProviderIDs.contains(id)) { refreshKeys() }
            } else {
                ContentUnavailableView("Provider removed", systemImage: "cloud")
            }
        }
        .sheet(isPresented: $addingCustom) {
            CustomProviderSheet()
        }
        .onAppear(perform: refreshKeys)
    }

    @ViewBuilder
    private func group(_ title: String, _ providers: [ProviderDescriptor]) -> some View {
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(providers) { provider in
                        NavigationLink(value: provider.id) {
                            ProviderCard(provider: provider, hasKey: keyed.contains(provider.id))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func refreshKeys() {
        keyed = Set(model.catalog.all.map(\.id).filter {
            model.keyStore.hasSecret(account: KeychainKeyStore.keyAccount($0))
        })
    }
}

private struct ProviderCard: View {
    var provider: ProviderDescriptor
    var hasKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(provider.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 2)
                if hasKey { Image(systemName: "key.fill").foregroundStyle(.green).accessibilityLabel("Key saved") }
            }
            KindBadge(kind: provider.kind)
            Text("\(provider.models.count) models").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
    }
}

/// Key, base URL, model picker, Test.
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
                Section {
                    SecureField(hasKey ? "Replace the saved key" : "Paste your key", text: $keyInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save Key") { saveKey(keyInput) }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    if hasKey { Button("Remove Key", role: .destructive) { saveKey(nil) } }
                    if let keyURL = provider.keyURL.flatMap(URL.init(string:)) { Link("Get a key", destination: keyURL) }
                } header: {
                    Text("API key")
                } footer: {
                    Text(hasKey ? "A key is saved in the Keychain." : (provider.requiresAPIKey ? "No key saved." : "A key is optional."))
                }
            }

            Section {
                TextField(baseURLPrompt, text: $baseURLInput)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Save Base URL") { saveBaseURL() }
            } header: {
                Text("Base URL")
            } footer: {
                Text(baseURLHint)
            }

            Section("Model") {
                Picker("Model", selection: $modelID) {
                    Text("Default (\(provider.defaultModel.isEmpty ? "none" : provider.defaultModel))").tag("")
                    ForEach(modelOptions, id: \.id) { info in
                        Text(info.free ? "\(info.displayName) (free)" : info.displayName).tag(info.id)
                    }
                }
                TextField("Or type a model id", text: $modelID)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Fetch Models") { fetchModels() }.buttonStyle(.borderless)
                    Spacer()
                    if busy { ProgressView() }
                    Spacer()
                    Button("Test") { test() }.buttonStyle(.borderless)
                }
                Button("Use for the Agent") {
                    agentProvider = provider.id.rawValue
                    agentModel = effectiveModel
                    message = "The agent now uses \(effectiveModel)."
                }
                .disabled(effectiveModel.isEmpty)
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
                        Task { try? await model.removeCustomProvider(provider.id) }
                    }
                }
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var effectiveModel: String { modelID.isEmpty ? provider.defaultModel : modelID }

    private var modelOptions: [ModelInfo] {
        var seen = Set<String>()
        return (provider.modelInfos + listed).filter { seen.insert($0.id).inserted }
    }

    private var baseURLPrompt: String {
        let names = provider.baseURLPlaceholders
        if !names.isEmpty { return names.map { "\($0)=…" }.joined(separator: "&") }
        return provider.baseURL.isEmpty ? "https://host/v1" : "Default: \(provider.baseURL)"
    }

    private var baseURLHint: String {
        let names = provider.baseURLPlaceholders
        if !names.isEmpty { return "Needs \(names.map { "{\($0)}" }.joined(separator: ", ")) in \(provider.baseURL), or a full https:// URL." }
        return "Empty = the default URL. A full http(s) URL replaces it (gateways, proxies, your own server)."
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
    @State private var name = ""
    @State private var baseURL = "https://"
    @State private var requiresKey = true
    @State private var models = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("Base URL (ending in /v1)", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Toggle("Needs an API key", isOn: $requiresKey)
                TextField("Model ids (comma separated)", text: $models)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .navigationTitle("Add a provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: baseURL)?.host == nil)
                }
            }
        }
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
                dismiss()
            } catch {
                self.error = Format.describe(error)
            }
        }
    }
}
