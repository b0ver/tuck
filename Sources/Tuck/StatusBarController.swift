import AppKit

/// Owns the two status items (toggle chevron + expandable separator) and the
/// collapse/expand state. Hiding works the same way as Hidden Bar / Ice: when
/// collapsed, the separator item's length grows huge, pushing everything to its
/// left off the screen edge.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let bar = NSStatusBar.system

    private(set) var toggleItem: NSStatusItem!
    private(set) var separatorItem: NSStatusItem!
    private(set) var isCollapsed = false

    private let panel = HiddenItemsPanelController()
    let pins = PinnedItemsController()
    private var autoCollapseTimer: Timer?
    private var menuDismissMonitor: Any?
    private var menuDismissLocalMonitor: Any?

    private let expandedSeparatorLength: CGFloat = 14
    private let collapsedSeparatorLength: CGFloat = 10_000

    // MARK: - Setup

    func setUp() {
        pins.statusBar = self
        seedPreferredPositionsIfNeeded()

        separatorItem = bar.statusItem(withLength: expandedSeparatorLength)
        separatorItem.autosaveName = "tuck.separator"
        separatorItem.button?.image = Self.separatorImage
        separatorItem.button?.toolTip = L("separator.tooltip")

        toggleItem = bar.statusItem(withLength: NSStatusItem.squareLength)
        toggleItem.autosaveName = "tuck.toggle"
        toggleItem.behavior = []
        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(toggleClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Tuck"
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )

        applySeparatorVisibility()
        updateToggleImage()
        if Prefs.shared.startCollapsed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.collapse()
            }
        }
    }

    /// Default layout, right to left: [pins] [toggle] [separator] — so pinned
    /// icons sit to the right of the chevron, next to the system area.
    private func seedPreferredPositionsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "didSeedPositionsV2") else { return }
        d.set(true, forKey: "didSeedPositionsV2")
        Prefs.shared.didSeedPositions = true
        d.set(6, forKey: "NSStatusItem Preferred Position tuck.pins")
        d.set(40, forKey: "NSStatusItem Preferred Position tuck.toggle")
        d.set(76, forKey: "NSStatusItem Preferred Position tuck.separator")
    }

    // MARK: - Collapse / expand

    func collapse() {
        panel.close()
        isCollapsed = true
        separatorItem.length = collapsedSeparatorLength
        updateToggleImage()
        cancelAutoCollapse()
        // Hidden items reach their off-screen positions a beat after the
        // separator grows; refresh pinned proxies once they have.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.pins.refresh()
        }
    }

    func expand(startAutoCollapseTimer: Bool = true) {
        isCollapsed = false
        separatorItem.length = expandedSeparatorLength
        updateToggleImage()
        if startAutoCollapseTimer {
            scheduleAutoCollapse()
        }
    }

    func toggleCollapse() {
        if isCollapsed {
            expand()
        } else {
            collapse()
        }
    }

    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        let delay = Prefs.shared.autoCollapseSeconds
        guard delay > 0 else { return }
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.collapse()
        }
    }

    private func cancelAutoCollapse() {
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = nil
    }

    // MARK: - Click handling

    @objc private func toggleClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
            return
        }

        var style = Prefs.shared.revealStyle
        if event.modifierFlags.contains(.option) {
            style = (style == .panel) ? .inline : .panel
        }

        switch style {
        case .inline:
            toggleCollapse()
        case .panel:
            if panel.isShown {
                panel.close()
            } else {
                showPanelCollapsingFirst()
            }
        }
    }

    /// The panel reads hidden items in their off-screen (collapsed) positions,
    /// so make sure the bar is collapsed before showing it.
    private func showPanelCollapsingFirst() {
        if isCollapsed {
            panel.show(from: self)
            return
        }
        collapse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.panel.show(from: self)
        }
    }

    // MARK: - Panel click forwarding

    /// Called by the panel or a pinned proxy when the user picks a hidden
    /// icon: expand the bar so the item comes on screen, activate it (via the
    /// Accessibility press action, which leaves the cursor in place, or a
    /// cursor-restoring click for system modules), then collapse again once
    /// the opened menu is dismissed.
    func forwardClick(to item: BarItem, rightButton: Bool = false) {
        let savedCursor = CGEvent(source: nil)?.location
        expand(startAutoCollapseTimer: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            MenuBarItemService.activate(item, rightButton: rightButton, restoreCursorTo: savedCursor)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.collapseAfterNextGlobalClick()
            }
        }
    }

    /// Collapse shortly after the user's next click anywhere (which dismisses
    /// whatever menu the forwarded click opened). Global monitors do not see
    /// clicks on our own UI, so a local monitor covers those. Falls back to a
    /// timer in case no click ever arrives.
    private func collapseAfterNextGlobalClick() {
        removeMenuDismissMonitors()
        let trigger: () -> Void = { [weak self] in
            guard let self else { return }
            self.removeMenuDismissMonitors()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                // Don't fight the panel: if the click that dismissed the
                // forwarded menu was the user opening the panel, let it be.
                guard !self.panel.isShown, !self.panel.isPreparing else { return }
                self.collapse()
            }
        }
        menuDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in trigger() }
        menuDismissLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            trigger()
            return event
        }
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.removeMenuDismissMonitors()
            self?.collapse()
        }
    }

    private func removeMenuDismissMonitors() {
        if let monitor = menuDismissMonitor {
            NSEvent.removeMonitor(monitor)
            menuDismissMonitor = nil
        }
        if let monitor = menuDismissLocalMonitor {
            NSEvent.removeMonitor(monitor)
            menuDismissLocalMonitor = nil
        }
    }

    // MARK: - Context menu

    private func showContextMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let header = NSMenuItem(title: "Tuck \(version)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleTitle = isCollapsed ? L("menu.toggle.expand") : L("menu.toggle.collapse")
        menu.addItem(withTitle: toggleTitle, action: #selector(menuToggle), keyEquivalent: "")
        menu.addItem(withTitle: L("menu.panel"), action: #selector(menuShowPanel), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: L("menu.settings"), action: #selector(menuSettings), keyEquivalent: ",")

        let login = NSMenuItem(title: L("menu.launchAtLogin"), action: #selector(menuLaunchAtLogin), keyEquivalent: "")
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(withTitle: L("menu.quit"), action: #selector(menuQuit), keyEquivalent: "q")

        for item in menu.items { item.target = self }

        toggleItem.menu = menu
        toggleItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        toggleItem.menu = nil
    }

    @objc private func menuToggle() { toggleCollapse() }

    @objc private func menuShowPanel() {
        showPanelCollapsingFirst()
    }

    @objc private func menuSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func menuLaunchAtLogin() {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Appearance

    @objc private func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.applySeparatorVisibility()
        }
    }

    private func applySeparatorVisibility() {
        separatorItem.button?.image = Prefs.shared.showSeparator ? Self.separatorImage : nil
    }

    private func updateToggleImage() {
        let name = isCollapsed ? "chevron.compact.left" : "chevron.compact.right"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Tuck")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        toggleItem.button?.image = image
    }

    private static let separatorImage: NSImage = {
        let size = NSSize(width: 10, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let bar = NSBezierPath(
                roundedRect: NSRect(x: 4.25, y: 2, width: 1.5, height: 14),
                xRadius: 0.75,
                yRadius: 0.75
            )
            NSColor.black.withAlphaComponent(0.85).setFill()
            bar.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
