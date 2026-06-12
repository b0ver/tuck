import AppKit

/// Manages "pinned" icons: Tuck cannot physically move another app's status
/// item out of the hidden section (only the user can, with ⌘-drag), so a pin
/// is a proxy — Tuck's own status item that shows a live snapshot of the
/// hidden icon next to the Tuck button and forwards clicks to the real one.
final class PinnedItemsController {
    weak var statusBar: StatusBarController?

    private var proxies: [String: NSStatusItem] = [:]   // pin key → proxy item
    private var currentItems: [String: BarItem] = [:]   // pin key → live match

    // MARK: - Pin / unpin

    func pin(key: String) {
        var pinned = Prefs.shared.pinnedItems
        guard !pinned.contains(where: { MenuBarItemService.keysMatch($0, key) }) else { return }
        pinned.append(key)
        Prefs.shared.pinnedItems = pinned
        refresh()
    }

    func unpin(key: String) {
        Prefs.shared.pinnedItems.removeAll { $0 == key }
        if let proxy = proxies.removeValue(forKey: key) {
            NSStatusBar.system.removeStatusItem(proxy)
        }
        currentItems[key] = nil
        refresh()
    }

    // MARK: - Refresh

    /// Rebuild proxies from the current hidden items. Only meaningful while
    /// the bar is collapsed (hidden items are identified by off-screen x).
    func refresh() {
        guard let statusBar, statusBar.isCollapsed else { return }
        let pinned = Prefs.shared.pinnedItems
        guard !pinned.isEmpty || !proxies.isEmpty else { return }

        var items = MenuBarItemService.annotateWithApps(
            MenuBarItemService.hiddenItemsWhileCollapsed()
        )
        items = items.map { item in
            var item = item
            item.image = statusBar.previewCache[item.id]
            return item
        }
        let keys = MenuBarItemService.identityKeys(for: items)

        var matches: [String: BarItem] = [:]
        for item in items {
            guard let key = keys[item.id] else { continue }
            if let storedKey = pinned.first(where: { MenuBarItemService.keysMatch($0, key) }) {
                matches[storedKey] = item
            }
        }
        currentItems = matches

        // Drop proxies that are unpinned or whose item is gone (app quit).
        for (key, proxy) in proxies where matches[key] == nil {
            NSStatusBar.system.removeStatusItem(proxy)
            proxies[key] = nil
        }

        for key in pinned {
            guard let item = matches[key] else { continue }
            let proxy = proxies[key] ?? makeProxy(for: key)
            proxies[key] = proxy
            updateImage(of: proxy, with: item)
        }
    }

    private func makeProxy(for key: String) -> NSStatusItem {
        let autosave = "tuck.pin.\(stableSuffix(of: key))"
        // New pins land near the right edge, next to the Tuck button.
        let positionKey = "NSStatusItem Preferred Position \(autosave)"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }

        let proxy = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        proxy.autosaveName = autosave
        if let button = proxy.button {
            button.target = self
            button.action = #selector(proxyClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = L("pin.tooltip")
        }
        return proxy
    }

    private func updateImage(of proxy: NSStatusItem, with item: BarItem) {
        guard let button = proxy.button else { return }
        button.toolTip = "\(item.displayTitle) — \(L("pin.tooltip"))"
        if let image = item.image, let copy = image.copy() as? NSImage {
            let height: CGFloat = 22
            let width = max(8, image.size.width * height / max(1, image.size.height))
            copy.size = NSSize(width: width, height: height)
            button.image = copy
        } else if let fallback = item.fallbackIcon, let copy = fallback.copy() as? NSImage {
            copy.size = NSSize(width: 18, height: 18)
            button.image = copy
        } else {
            button.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        }
    }

    private func stableSuffix(of key: String) -> String {
        // djb2 — stable across launches, unlike Hashable.hashValue.
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return String(hash, radix: 36)
    }

    // MARK: - Clicks

    @objc private func proxyClicked(_ sender: NSStatusBarButton) {
        guard let (key, _) = proxies.first(where: { $0.value.button === sender }),
              let item = currentItems[key]
        else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let unpinItem = NSMenuItem(title: L("pin.unpin"), action: #selector(unpinClicked(_:)), keyEquivalent: "")
            unpinItem.target = self
            unpinItem.representedObject = key
            menu.addItem(unpinItem)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        } else {
            statusBar?.forwardClick(to: item)
        }
    }

    @objc private func unpinClicked(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        unpin(key: key)
    }
}
