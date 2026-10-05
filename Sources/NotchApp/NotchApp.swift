import SwiftUI
import AppKit

@main
struct NotchAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var theme = ThemeManager.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(theme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotchManager.shared.setup()
        RemoteCommands.setup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
