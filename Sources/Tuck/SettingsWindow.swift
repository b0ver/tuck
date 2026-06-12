import AppKit
import SwiftUI

// MARK: - Window controller

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    convenience init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Root view

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(L("tab.general"), systemImage: "gearshape") }
            BehaviorTab()
                .tabItem { Label(L("tab.behavior"), systemImage: "cursorarrow.click.2") }
            PermissionsTab()
                .tabItem { Label(L("tab.permissions"), systemImage: "lock.shield") }
            AboutTab()
                .tabItem { Label(L("tab.about"), systemImage: "info.circle") }
        }
        .frame(width: 460)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(Prefs.Key.startCollapsed) private var startCollapsed = true
    @AppStorage(Prefs.Key.showSeparator) private var showSeparator = true
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle(L("general.launchAtLogin"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        if !LaunchAtLogin.set(newValue) {
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                Toggle(L("general.startCollapsed"), isOn: $startCollapsed)
                Toggle(L("general.showSeparator"), isOn: $showSeparator)
            }
            Section {
                Label {
                    Text(L("general.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "hand.draw")
                        .foregroundStyle(.tint)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 280)
    }
}

// MARK: - Behavior

private struct BehaviorTab: View {
    @AppStorage(Prefs.Key.revealStyle) private var revealStyle = RevealStyle.panel.rawValue
    @AppStorage(Prefs.Key.autoCollapseSeconds) private var autoCollapse = 15.0
    @AppStorage(Prefs.Key.panelIconsPerRow) private var iconsPerRow = 10

    private let delays: [Double] = [0, 5, 10, 15, 30, 60]

    var body: some View {
        Form {
            Section {
                Picker(L("behavior.reveal"), selection: $revealStyle) {
                    Text(L("behavior.reveal.panel")).tag(RevealStyle.panel.rawValue)
                    Text(L("behavior.reveal.inline")).tag(RevealStyle.inline.rawValue)
                }
                .pickerStyle(.inline)
            }
            Section {
                Picker(L("behavior.autocollapse"), selection: $autoCollapse) {
                    ForEach(delays, id: \.self) { delay in
                        if delay == 0 {
                            Text(L("behavior.autocollapse.never")).tag(0.0)
                        } else {
                            Text(L("behavior.seconds", Int(delay))).tag(delay)
                        }
                    }
                }
                Stepper(value: $iconsPerRow, in: 4...20) {
                    HStack {
                        Text(L("behavior.iconsPerRow"))
                        Spacer()
                        Text("\(iconsPerRow)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Section {
                Label {
                    Text(L("behavior.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "option")
                        .foregroundStyle(.tint)
                }
                Label {
                    Text(L("pin.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "pin")
                        .foregroundStyle(.tint)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @State private var screenGranted = MenuBarItemService.hasScreenCaptureAccess
    @State private var axGranted = MenuBarItemService.hasAccessibilityAccess

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                permissionRow(
                    granted: screenGranted,
                    title: L("perm.screen"),
                    description: L("perm.screen.desc"),
                    request: {
                        CGRequestScreenCaptureAccess()
                        openPrivacyPane("Privacy_ScreenCapture")
                    }
                )
                permissionRow(
                    granted: axGranted,
                    title: L("perm.ax"),
                    description: L("perm.ax.desc"),
                    request: {
                        MenuBarItemService.requestAccessibilityAccess()
                        openPrivacyPane("Privacy_Accessibility")
                    }
                )
            }
            Section {
                Label {
                    Text(L("perm.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.tint)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
        .onReceive(refresh) { _ in
            screenGranted = MenuBarItemService.hasScreenCaptureAccess
            axGranted = MenuBarItemService.hasAccessibilityAccess
        }
    }

    @ViewBuilder
    private func permissionRow(granted: Bool, title: String, description: String, request: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L("perm.request"), action: request)
            } else {
                Text(L("perm.granted"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func openPrivacyPane(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - About

private struct AboutTab: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Tuck")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(L("about.tagline"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("about.version", version))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Link("GitHub — b0ver/tuck", destination: URL(string: "https://github.com/b0ver/tuck")!)
                .font(.callout)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .frame(height: 300)
    }
}
