import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusBar = StatusBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        statusBar.setUp()

        // Accessibility is mandatory on macOS 26 (the menu bar can no longer be
        // captured). If it isn't granted, surface the requirement immediately
        // rather than letting the panel come up empty.
        if !MenuBarItemService.hasAccessibilityAccess {
            MenuBarItemService.requestAccessibilityAccess()
            SettingsWindowController.shared.show(tab: .permissions)
        } else if Prefs.shared.isFirstLaunch {
            Prefs.shared.isFirstLaunch = false
            SettingsWindowController.shared.show()
        }

        NotificationCenter.default.addObserver(
            forName: .tuckPinsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusBar.pins.refresh()
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
