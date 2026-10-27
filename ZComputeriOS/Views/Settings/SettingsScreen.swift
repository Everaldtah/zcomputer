import SwiftUI
import ZAgent
import ZCore
import ZLocal

/// Settings: Providers, Local models, Agent policy, About.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ProvidersScreen()
                    } label: {
                        Label("Providers", systemImage: "cloud")
                    }
                    NavigationLink {
                        LocalModelsScreen()
                    } label: {
                        Label("Local models", systemImage: "cpu")
                    }
                    NavigationLink {
                        AgentSettingsScreen()
                    } label: {
                        Label("Agent", systemImage: "sparkles")
                    }
                    NavigationLink {
                        AboutScreen()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                Section("Agent model") {
                    Text(AgentSettings.modelRef().map { model.displayName(for: $0) } ?? "None chosen yet")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// The agent policy (ZAgent `AgentPolicy`) and screenshot consents.
struct AgentSettingsScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKey.approvalMode) private var approvalMode = ApprovalMode.destructiveOnly.rawValue
    @AppStorage(SettingsKey.maxSteps) private var maxSteps = 50
    @AppStorage(SettingsKey.screenshotMaxEdge) private var screenshotMaxEdge = ScreenshotScaler.defaultMaxLongEdge
    @AppStorage(SettingsKey.stepDelay) private var stepDelay = 0.0
    @AppStorage(SettingsKey.toolCallMode) private var toolCallMode = ToolCallMode.auto.rawValue
    @AppStorage(SettingsKey.nativeComputerUse) private var nativeComputerUse = true
    @AppStorage(SettingsKey.keepScreenshots) private var keepScreenshots = 3
    @AppStorage(SettingsKey.agentProvider) private var providerRaw = ""
    @AppStorage(SettingsKey.agentModel) private var modelID = ""
    @State private var consents: [String] = []

    var body: some View {
        Form {
            Section {
                ModelMenu(selection: providerRaw.isEmpty || modelID.isEmpty
                          ? nil : ModelRef(provider: ProviderID(providerRaw), model: modelID)) { ref in
                    providerRaw = ref.provider.rawValue
                    modelID = ref.model
                }
            } header: {
                Text("Agent model")
            } footer: {
                Text("Pick from your providers (keys in Providers), your model servers or downloaded MLX models.")
            }
            Section("Approvals") {
                Picker("Ask before", selection: $approvalMode) {
                    Text("Destructive actions only").tag(ApprovalMode.destructiveOnly.rawValue)
                    Text("Every action that changes something").tag(ApprovalMode.always.rawValue)
                    Text("Never (fully autonomous)").tag(ApprovalMode.never.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Run") {
                Stepper("Maximum steps: \(maxSteps)", value: $maxSteps, in: 5...300, step: 5)
                Stepper("Pause between steps: \(String(format: "%.1f", stepDelay)) s", value: $stepDelay, in: 0...10, step: 0.5)
                Picker("Tool calls", selection: $toolCallMode) {
                    Text("Automatic").tag(ToolCallMode.auto.rawValue)
                    Text("Native tool calling").tag(ToolCallMode.native.rawValue)
                    Text("Text blocks (models without tools)").tag(ToolCallMode.text.rawValue)
                }
                Toggle("Use the provider's native computer-use tool", isOn: $nativeComputerUse)
            }
            Section("Screenshots") {
                Picker("Longest side sent to the model", selection: $screenshotMaxEdge) {
                    ForEach([800, 1024, 1280, 1366], id: \.self) { Text("\($0) px").tag($0) }
                }
                Stepper("Kept in context: \(keepScreenshots)", value: $keepScreenshots, in: 1...10)
            }
            Section("Sending screenshots to cloud providers") {
                if consents.isEmpty {
                    Text("No cloud provider may receive screenshots yet; the agent asks the first time.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(consents, id: \.self) { provider in
                        HStack {
                            Text(model.catalog.provider(ProviderID(provider))?.name ?? provider)
                            Spacer()
                            Button("Withdraw") {
                                AgentSettings.setCloudConsent(ProviderID(provider), granted: false)
                                consents = AgentSettings.consentedProviders()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Withdraw all", role: .destructive) {
                        AgentSettings.resetCloudConsents()
                        consents = []
                    }
                }
            }
        }
        .navigationTitle("Agent")
        .onAppear { consents = AgentSettings.consentedProviders() }
    }
}

struct AboutScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
                LabeledContent("Machines", value: model.machines.engine.engineName)
                LabeledContent("In-app MLX models", value: LocalModelsModel.hasMLXRuntime ? "Included" : "Not in this build")
                LabeledContent("Device memory", value: "\(model.host.ramGB) GB")
                LabeledContent("Library") {
                    Text(model.memoryStatus).font(.caption).multilineTextAlignment(.trailing)
                }
            }
            Section("What Z Computer does") {
                Text("Z Computer runs a small x86 Linux machine inside the app (emulated in WebKit) and lets AI agents "
                     + "see and control it: agents take screenshots, move the pointer, type and use the serial console. "
                     + "You see every step in Activity, approve risky actions, and can stop an agent at any time. "
                     + "Screenshots go to a cloud AI provider only after you allow it.")
            }
        }
        .navigationTitle("About")
    }
}
