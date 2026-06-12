import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        statusBar.setUp()

        if Prefs.shared.isFirstLaunch {
            Prefs.shared.isFirstLaunch = false
            SettingsWindowController.shared.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Double-clicking the app in Finder while it is already running opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
}
