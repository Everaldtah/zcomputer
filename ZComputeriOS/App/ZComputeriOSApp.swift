import SwiftUI

@main
struct ZComputeriOSApp: App {
    @State private var model = AppModel(engine: ZComputeriOSApp.makeEngine())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: model.machines.appDidEnterBackground()
                    case .active: model.machines.appWillEnterForeground()
                    default: break
                    }
                }
        }
    }

    /// The emulator when this build links ZEmu, otherwise a stand-in that lists the catalogue only.
    @MainActor
    static func makeEngine() -> any MachineEngine {
        #if canImport(ZEmu)
        return ZEmuMachineEngine()
        #else
        return UnavailableMachineEngine()
        #endif
    }
}

/// Tabs, the parked machine screens behind them, and the agent-watching indicator on top of every tab.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var machines = model.machines
        TabView(selection: $model.tab) {
            MachinesScreen()
                .tabItem { Label(AppTab.machines.title, systemImage: AppTab.machines.systemImage) }
                .tag(AppTab.machines)
            AgentScreen()
                .tabItem { Label(AppTab.agent.title, systemImage: AppTab.agent.systemImage) }
                .tag(AppTab.agent)
                .badge(model.agent.pendingApprovals.count)
            TeamScreen()
                .tabItem { Label(AppTab.team.title, systemImage: AppTab.team.systemImage) }
                .tag(AppTab.team)
            LibraryScreen()
                .tabItem { Label(AppTab.library.title, systemImage: AppTab.library.systemImage) }
                .tag(AppTab.library)
            TerminalScreen()
                .tabItem { Label(AppTab.terminal.title, systemImage: AppTab.terminal.systemImage) }
                .tag(AppTab.terminal)
            SettingsScreen()
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage) }
                .tag(AppTab.settings)
        }
        .background {
            // Running machines' WebKit screens wait here (in the window, covered by the tabs) when no screen shows them.
            ParkingLotView(parking: model.machines.parking)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if model.agent.isControllingMachine, model.tab != .agent {
                AgentControllingBanner(compact: true)
                    .padding(.top, 4)
            }
        }
        .fullScreenCover(item: $machines.presented) { entry in
            MachineScreen(entry: entry)
                .environment(model)
        }
        .sheet(item: Binding(get: { model.agent.consentRequest }, set: { model.agent.consentRequest = $0 })) { request in
            CloudConsentSheet(request: request)
                .environment(model)
                .interactiveDismissDisabled()
        }
    }
}
