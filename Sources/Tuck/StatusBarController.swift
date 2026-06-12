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
            // Give the status bar a moment to settle, then collapse() — it
            // snapshots the visible icons into the preview cache first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.collapse()
            }
        }
    }

    /// Place the toggle right next to the system area and the separator just
    /// left of it, so freshly installed users get a sane default layout.
    private func seedPreferredPositionsIfNeeded() {
        guard !Prefs.shared.didSeedPositions else { return }
        Prefs.shared.didSeedPositions = true
        let d = UserDefaults.standard
        d.set(0, forKey: "NSStatusItem Preferred Position tuck.toggle")
        d.set(40, forKey: "NSStatusItem Preferred Position tuck.separator")
    }

    // MARK: - Preview cache

    /// Latest snapshots of menu bar icons, keyed by window id. Refreshed
    /// whenever the icons are visible (launch, every collapse), because
    /// display capture cannot see them once they are pushed off-screen.
    private(set) var previewCache: [CGWindowID: NSImage] = [:]

    @MainActor
    func refreshPreviewCache() async {
        let visible = MenuBarItemService.visibleItems()
        let captured = await MenuBarItemService.capturePreviews(of: visible)
        if !captured.isEmpty {
            previewCache.merge(captured) { _, new in new }
        }
    }

    // MARK: - Collapse / expand

    /// Snapshot the visible icons for the panel previews, then hide them.
    func collapse() {
        if isCollapsed {
            applyCollapsedState()
            return
        }
        Task { @MainActor in
            await refreshPreviewCache()
            self.applyCollapsedState()
        }
    }

    /// Hide immediately without refreshing the preview cache.
    func collapseWithoutCapture() {
        applyCollapsedState()
    }

    private func applyCollapsedState() {
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

    /// The panel enumerates hidden items in their off-screen (collapsed)
    /// positions, so make sure the bar is collapsed before showing it —
    /// refreshing the preview cache on the way since the icons are visible.
    private func showPanelCollapsingFirst() {
        if isCollapsed {
            panel.show(from: self)
            return
        }
        Task { @MainActor in
            await refreshPreviewCache()
            collapseWithoutCapture()
            try? await Task.sleep(nanoseconds: 250_000_000)
            panel.show(from: self)
        }
    }

    // MARK: - Panel click forwarding

    /// Called by the panel when the user picks a hidden icon: expand the bar,
    /// synthesize a click on the real status item, then collapse again once
    /// the opened menu is dismissed.
    func forwardClick(to item: BarItem) {
        expand(startAutoCollapseTimer: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            if let frame = MenuBarItemService.currentFrame(of: item.id) {
                MenuBarItemService.postClick(at: CGPoint(x: frame.midX, y: frame.midY))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.collapseAfterNextGlobalClick()
            }
        }
    }

    /// Collapse shortly after the user's next click anywhere (which dismisses
    /// whatever menu the forwarded click opened). Falls back to a timer.
    private func collapseAfterNextGlobalClick() {
        removeMenuDismissMonitor()
        menuDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            self.removeMenuDismissMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.collapse()
            }
        }
        // Fallback in case no click ever arrives.
        autoCollapseTimer?.invalidate()
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.removeMenuDismissMonitor()
            self?.collapse()
        }
    }

    private func removeMenuDismissMonitor() {
        if let monitor = menuDismissMonitor {
            NSEvent.removeMonitor(monitor)
            menuDismissMonitor = nil
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
