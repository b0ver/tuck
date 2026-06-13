import AppKit
import SwiftUI

// MARK: - Window controller

enum SettingsTab: Hashable {
    case general, behavior, icons, permissions, about
}

extension Notification.Name {
    /// Posted when the set of pinned icons changes, so the pin strip refreshes.
    static let tuckPinsChanged = Notification.Name("tuck.pinsChanged")
}

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let selection = SettingsSelection()

    convenience init() {
        let selection = SettingsSelection()
        let hosting = NSHostingController(rootView: SettingsView(selection: selection))
        let window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
        // Replace the throwaway selection with one we keep a reference to.
        hosting.rootView = SettingsView(selection: self.selection)
    }

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

// MARK: - Root view

struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralTab()
                .tabItem { Label(L("tab.general"), systemImage: "gearshape") }
                .tag(SettingsTab.general)
            BehaviorTab()
                .tabItem { Label(L("tab.behavior"), systemImage: "cursorarrow.click.2") }
                .tag(SettingsTab.behavior)
            IconsTab()
                .tabItem { Label(L("tab.icons"), systemImage: "pin") }
                .tag(SettingsTab.icons)
            PermissionsTab()
                .tabItem { Label(L("tab.permissions"), systemImage: "lock.shield") }
                .tag(SettingsTab.permissions)
            AboutTab()
                .tabItem { Label(L("tab.about"), systemImage: "info.circle") }
                .tag(SettingsTab.about)
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

// MARK: - Icons (pinning)

private struct IconsTab: View {
    @State private var items: [BarItem] = []
    @State private var pinned: [String] = Prefs.shared.pinnedItems
    @State private var axGranted = MenuBarItemService.hasAccessibilityAccess

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !axGranted {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield").font(.system(size: 24)).foregroundStyle(.tint)
                    Text(L("perm.hint")).font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                Text(L("icons.empty")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    } footer: {
                        Text(L("icons.hint")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(height: 400)
        .onAppear { reload() }
        .onReceive(refresh) { _ in reload() }
    }

    private func row(for item: BarItem) -> some View {
        HStack(spacing: 10) {
            if let icon = item.icon {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary)
            }
            Text(item.displayTitle).lineLimit(1)
            Spacer()
            Toggle("", isOn: binding(for: item)).labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func binding(for item: BarItem) -> Binding<Bool> {
        Binding(
            get: { pinned.contains { MenuBarItemService.keysMatch($0, item.id) } },
            set: { isOn in
                if isOn {
                    if !pinned.contains(where: { MenuBarItemService.keysMatch($0, item.id) }) {
                        pinned.append(item.id)
                    }
                } else {
                    pinned.removeAll { MenuBarItemService.keysMatch($0, item.id) }
                }
                Prefs.shared.pinnedItems = pinned
                NotificationCenter.default.post(name: .tuckPinsChanged, object: nil)
            }
        )
    }

    private func reload() {
        axGranted = MenuBarItemService.hasAccessibilityAccess
        guard axGranted else { return }
        items = MenuBarItemService.allItems()
        pinned = Prefs.shared.pinnedItems
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    @State private var axGranted = MenuBarItemService.hasAccessibilityAccess

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
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
        .frame(height: 280)
        .onReceive(refresh) { _ in
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
