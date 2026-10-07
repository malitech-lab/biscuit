import BiscuitKit
import SwiftUI

@main
struct BiscuitMain: App {
    @State private var environment = AppEnvironment()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Biscuit", id: "main") {
            RootView()
                .environment(environment)
                .frame(minWidth: 820, minHeight: 640)
                .task { environment.start() }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .appInfo) {
                Button(t(.actionCheckForUpdates)) {
                    Task { await environment.updater.checkForUpdates(userInitiated: true) }
                }
                .disabled(environment.updater.isChecking)
            }

            CommandMenu(t(.menuDisks)) {
                Button(t(.actionRefreshDevices)) {
                    Task { await environment.monitor.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button(t(.actionCopyLog)) {
                    let text = environment.coordinator.exportableLog()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(environment)
        }
    }
}
