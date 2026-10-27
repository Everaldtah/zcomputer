import SwiftUI
import ZAgent
import ZCore
import ZLocal

/// Settings: Providers, Local models, Agent policy, About.
struct SettingsView: View {
    var body: some View {
        TabView {
            ProvidersSettingsView()
                .tabItem { Label("Providers", systemImage: "cloud") }
            LocalModelsSettingsView()
                .tabItem { Label("Local models", systemImage: "cpu") }
            AgentSettingsView()
                .tabItem { Label("Agent", systemImage: "sparkles") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(.top, 4)
    }
}

/// The agent policy (ZAgent `AgentPolicy`) and screenshot consents.
struct AgentSettingsView: View {
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
            Section("Model") {
                LabeledContent("Agent model") {
                    ModelMenu(selection: providerRaw.isEmpty || modelID.isEmpty
                              ? nil : ModelRef(provider: ProviderID(providerRaw), model: modelID)) { ref in
                        providerRaw = ref.provider.rawValue
                        modelID = ref.model
                    }
                        .frame(maxWidth: 320)
                }
                Text("Pick from your providers (keys in the Providers tab), local servers or downloaded MLX models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Approvals") {
                Picker("Ask before", selection: $approvalMode) {
                    Text("Destructive actions only (rm -rf, dd, shutdown, curl | sh …)").tag(ApprovalMode.destructiveOnly.rawValue)
                    Text("Every action that changes something").tag(ApprovalMode.always.rawValue)
                    Text("Never (fully autonomous)").tag(ApprovalMode.never.rawValue)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Run") {
                Stepper("Maximum steps per task: \(maxSteps)", value: $maxSteps, in: 5...300, step: 5)
                Stepper("Pause between steps: \(String(format: "%.1f", stepDelay)) s", value: $stepDelay, in: 0...10, step: 0.5)
                Picker("Tool calls", selection: $toolCallMode) {
                    Text("Automatic").tag(ToolCallMode.auto.rawValue)
                    Text("Native tool calling").tag(ToolCallMode.native.rawValue)
                    Text("Text blocks (models without tools)").tag(ToolCallMode.text.rawValue)
                }
                Toggle("Use the provider's native computer-use tool when the model has one", isOn: $nativeComputerUse)
            }
            Section("Screenshots") {
                Picker("Longest side sent to the model", selection: $screenshotMaxEdge) {
                    ForEach([1024, 1280, 1366, 1600, 1920], id: \.self) { Text("\($0) px").tag($0) }
                }
                Stepper("Screenshots kept in context: \(keepScreenshots)", value: $keepScreenshots, in: 1...10)
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
                        }
                    }
                    Button("Withdraw all", role: .destructive) {
                        AgentSettings.resetCloudConsents()
                        consents = []
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { consents = AgentSettings.consentedProviders() }
    }
}

struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Build", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
                LabeledContent("Library", value: model.memoryStatus)
                LabeledContent("In-app MLX models", value: LocalModelsModel.hasMLXRuntime ? "Included" : "Not in this build (ZC_MLX off)")
                LabeledContent("Guest agent binaries", value: AppPaths.guestAgentDirectory == nil ? "Missing (dev build)" : "Bundled")
            }
            Section("What Z Computer does") {
                Text("Z Computer runs virtual machines with Apple's Virtualization framework and lets AI agents see and "
                     + "control them: agents take screenshots of the VM, move the mouse, type, and run commands through "
                     + "the in-guest agent. You see every step in the Activity panel, approve risky actions, and can stop "
                     + "an agent at any time. Screenshots go to a cloud AI provider only after you allow it.")
            }
        }
        .formStyle(.grouped)
    }
}
