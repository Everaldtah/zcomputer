import SwiftUI

@main
struct ZComputerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Z Computer", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 680)
                .task { await model.start() }
        }
        .commands {
            SidebarCommands()
            CommandGroup(after: .sidebar) {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, item in
                    Button(item.title) { model.selection = item }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 600)
        }
    }
}
