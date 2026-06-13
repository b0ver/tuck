import AppKit

/// Manages "pinned" icons: Tuck cannot physically move another app's status
/// item out of the hidden section (only the user can, with ⌘-drag), so a pin
/// is a proxy — Tuck shows live stand-ins for chosen hidden icons to the
/// right of its chevron, behind a thin divider, and forwards clicks (left and
/// right) to the real items. ⌥-click a pinned icon to unpin it.
///
/// All pins live in a single status item container so their position relative
/// to the Tuck chevron is stable.
final class PinnedItemsController {
    weak var statusBar: StatusBarController?

    private var containerItem: NSStatusItem?
    private var currentItems: [String: BarItem] = [:]   // pin key → live match

    // MARK: - Pin / unpin

    func pin(key: String) {
        var pinned = Prefs.shared.pinnedItems
        guard !pinned.contains(where: { MenuBarItemService.keysMatch($0, key) }) else { return }
        pinned.append(key)
        Prefs.shared.pinnedItems = pinned
        TuckLog.log("pin: \(key)")
        refresh()
    }

    func unpin(key: String) {
        Prefs.shared.pinnedItems.removeAll { $0 == key }
        TuckLog.log("unpin: \(key)")
        refresh()
    }

    // MARK: - Refresh

    /// Rebuild the pin strip from the current hidden items. Only meaningful
    /// while the bar is collapsed (hidden items are identified by off-screen x).
    func refresh() {
        guard let statusBar, statusBar.isCollapsed else { return }
        let pinned = Prefs.shared.pinnedItems
        guard !pinned.isEmpty else {
            removeContainer()
            return
        }

        let items = MenuBarItemService.hiddenItems()

        var matches: [String: BarItem] = [:]
        for item in items {
            if let storedKey = pinned.first(where: { MenuBarItemService.keysMatch($0, item.id) }) {
                matches[storedKey] = item
            }
        }
        currentItems = matches

        let orderedKeys = pinned.filter { matches[$0] != nil }
        guard !orderedKeys.isEmpty else {
            removeContainer()
            return
        }
        rebuildStrip(keys: orderedKeys)
    }

    private func removeContainer() {
        if let containerItem {
            NSStatusBar.system.removeStatusItem(containerItem)
        }
        containerItem = nil
        currentItems = [:]
    }

    // MARK: - Strip UI

    private func ensureContainer() -> NSStatusItem {
        if let containerItem { return containerItem }
        // Default position: just right of the Tuck chevron (smaller preferred
        // position = closer to the system area).
        let positionKey = "NSStatusItem Preferred Position tuck.pins"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(6, forKey: positionKey)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "tuck.pins"
        containerItem = item
        return item
    }

    private func rebuildStrip(keys: [String]) {
        let item = ensureContainer()
        guard let button = item.button else { return }
        button.subviews.forEach { $0.removeFromSuperview() }
        button.image = nil

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4

        // The thin divider that visually separates pins from the chevron.
        let divider = NSBox()
        divider.boxType = .custom
        divider.borderWidth = 0
        divider.fillColor = NSColor.tertiaryLabelColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 13).isActive = true
        stack.addArrangedSubview(divider)

        for key in keys {
            guard let barItem = currentItems[key] else { continue }
            let pinButton = PinButton()
            pinButton.isBordered = false
            pinButton.imagePosition = .imageOnly
            pinButton.imageScaling = .scaleProportionallyDown
            pinButton.image = displayImage(for: barItem)
            pinButton.toolTip = "\(barItem.displayTitle) — \(L("pin.tooltip"))"
            pinButton.identifier = NSUserInterfaceItemIdentifier(key)
            pinButton.target = self
            pinButton.action = #selector(pinLeftClicked(_:))
            pinButton.onRightClick = { [weak self] option in
                self?.handleClick(key: key, right: true, option: option)
            }
            pinButton.translatesAutoresizingMaskIntoConstraints = false
            pinButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
            pinButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
            stack.addArrangedSubview(pinButton)
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            stack.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        item.length = 5 + 1 + CGFloat(keys.count) * 30 + 3
    }

    private func displayImage(for item: BarItem) -> NSImage? {
        if let icon = item.icon, let copy = icon.copy() as? NSImage {
            copy.size = NSSize(width: 18, height: 18)
            return copy
        }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
    }

    // MARK: - Clicks

    @objc private func pinLeftClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let option = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        handleClick(key: key, right: false, option: option)
    }

    private func handleClick(key: String, right: Bool, option: Bool) {
        if option {
            unpin(key: key)
            return
        }
        guard let item = currentItems[key] else { return }
        statusBar?.forwardClick(to: item, rightButton: right)
    }
}

/// NSButton that also reports right clicks (NSButton ignores them natively).
final class PinButton: NSButton {
    var onRightClick: ((_ optionHeld: Bool) -> Void)?

    override func rightMouseUp(with event: NSEvent) {
        onRightClick?(event.modifierFlags.contains(.option))
    }
}
