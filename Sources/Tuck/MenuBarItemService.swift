import AppKit
import ApplicationServices

/// A third-party / system status item, discovered through the Accessibility
/// API. On macOS 26 this is the only reliable source: every menu bar item
/// window is owned by the Control Center process and reported off-screen by
/// CGWindowList (with stale duplicates), and no capture API will photograph
/// the menu bar. AXExtrasMenuBar, by contrast, lists each app's real items
/// with the owning process, a live screen position, and a pressable element.
struct BarItem: Identifiable {
    /// Stable identity (bundle id + ordinal, or a Control Center module key).
    let id: String
    let pid: pid_t
    let bundleID: String?
    let appName: String?
    let axTitle: String?
    /// Live top-left screen position and size, as reported by AX.
    let position: CGPoint
    let size: CGSize
    /// The live AX element, used to re-read position and to press the item.
    let element: AXUIElement
    /// SF Symbol name for Control Center / system modules without an app icon.
    let systemSymbol: String?

    var isSystemOwned: Bool {
        guard let bundleID else { return true }
        return bundleID == "com.apple.controlcenter"
            || bundleID == "com.apple.systemuiserver"
            || bundleID == "com.apple.controlcenter.helper"
    }

    var displayTitle: String {
        if let axTitle, !axTitle.isEmpty { return axTitle }
        if let appName, !appName.isEmpty { return appName }
        return "?"
    }

    /// The icon shown in the panel and on pinned proxies: the owning app's
    /// icon for real apps, an SF Symbol for system modules.
    var icon: NSImage? {
        if !isSystemOwned, let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        if let systemSymbol,
           let img = NSImage(systemSymbolName: systemSymbol, accessibilityDescription: displayTitle) {
            return img.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        }
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        return nil
    }
}

enum MenuBarItemService {

    static var hasAccessibilityAccess: Bool { AXIsProcessTrusted() }

    static func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Enumeration

    /// All menu bar items across every running app, left to right, excluding
    /// Tuck's own items and zero/oversized elements. Empty without AX access.
    static func allItems() -> [BarItem] {
        guard AXIsProcessTrusted() else {
            TuckLog.log("enumerate: AX not trusted")
            return []
        }

        let ownPID = getpid()
        let names = systemModuleNamesByPosition()

        struct Raw {
            let pid: pid_t
            let bundle: String?
            let app: String?
            let title: String?
            let pos: CGPoint
            let size: CGSize
            let element: AXUIElement
        }

        var raws: [Raw] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != ownPID {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var barRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &barRef) == .success,
                  let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID()
            else { continue }
            let bar = unsafeDowncast(barRef, to: AXUIElement.self)

            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement]
            else { continue }

            for kid in kids {
                let pos = axPoint(kid, kAXPositionAttribute)
                let size = axSize(kid, kAXSizeAttribute)
                // Skip zero-size placeholders and the giant Tuck separator clones.
                guard size.width >= 1, size.width <= 300, size.height >= 1 else { continue }
                let title = axString(kid, kAXTitleAttribute) ?? axString(kid, kAXDescriptionAttribute)
                raws.append(Raw(pid: app.processIdentifier,
                                bundle: app.bundleIdentifier,
                                app: app.localizedName,
                                title: title,
                                pos: pos, size: size, element: kid))
            }
        }

        raws.sort { $0.pos.x < $1.pos.x }

        var counters: [String: Int] = [:]
        return raws.map { raw in
            let base = identityBase(bundle: raw.bundle, title: raw.title, pos: raw.pos, names: names)
            let n = counters[base, default: 0]
            counters[base] = n + 1
            let id = n == 0 ? base : "\(base)#\(n)"
            return BarItem(id: id, pid: raw.pid, bundleID: raw.bundle, appName: raw.app,
                           axTitle: raw.title, position: raw.pos, size: raw.size,
                           element: raw.element,
                           systemSymbol: systemSymbol(bundle: raw.bundle, title: raw.title,
                                                      pos: raw.pos, names: names))
        }
    }

    /// Items currently tucked off the left edge of the screen (hidden by the
    /// Tuck separator). Only meaningful while Tuck is collapsed.
    static func hiddenItems() -> [BarItem] {
        let items = allItems().filter { $0.position.x < 0 }
        TuckLog.log("enumerate: \(items.count) hidden items: " +
                    items.map { $0.id }.joined(separator: ", "))
        return items
    }

    // MARK: - Activation

    /// Re-read the element's live screen position (it moves when the bar
    /// expands), returning the click point at its center.
    static func currentClickPoint(of item: BarItem) -> CGPoint? {
        let pos = axPoint(item.element, kAXPositionAttribute)
        let size = axSize(item.element, kAXSizeAttribute)
        guard size.width >= 1 else { return nil }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    /// Activate the item, opening its menu. Prefers the Accessibility press
    /// action for app icons (it never moves the mouse cursor — the cause of
    /// the cursor "flying" to the real off-screen icon). Falls back to a
    /// synthesized click for right-clicks and for Control Center / system
    /// modules, which ignore AXPress; the cursor is then restored to where it
    /// was so it doesn't end up stranded over the menu bar.
    static func activate(_ item: BarItem, rightButton: Bool, restoreCursorTo saved: CGPoint?) {
        if rightButton {
            // Right-click forwards a real secondary click so the app's own
            // context menu opens. Leave the cursor on the menu so it's usable
            // (warping it away can dismiss a just-opened context menu).
            guard let point = currentClickPoint(of: item) else { return }
            postClick(at: point, rightButton: true)
            return
        }
        if !item.isSystemOwned {
            let err = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
            // .cannotComplete is returned by some apps even though the menu
            // does open, so treat it as success too.
            if err == .success || err == .cannotComplete { return }
        }
        // System modules ignore AXPress: synthesize a click, then put the
        // cursor back so it doesn't end up stranded over the menu bar.
        guard let point = currentClickPoint(of: item) else { return }
        postClick(at: point, rightButton: false)
        if let saved {
            usleep(40_000)
            CGWarpMouseCursorPosition(saved)
        }
    }

    /// Synthesize a click at a point in global display coordinates.
    static func postClick(at point: CGPoint, rightButton: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = rightButton ? .right : .left
        CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Identity helpers

    static func keysMatch(_ a: String, _ b: String) -> Bool { a == b }

    private static func identityBase(bundle: String?, title: String?, pos: CGPoint,
                                     names: [(CGFloat, String)]) -> String {
        if let bundle, bundle != "com.apple.controlcenter", bundle != "com.apple.systemuiserver" {
            return "b:" + bundle
        }
        // System modules share a bundle id, so key them by their module name.
        if let module = moduleName(title: title, pos: pos, names: names) {
            return "m:" + module
        }
        if let title, !title.isEmpty { return "t:" + title }
        return "x:\(Int(pos.x.rounded()))"
    }

    // MARK: - System module recognition

    /// Best-effort window names for system modules, keyed by x position.
    /// Requires Screen Recording; empty without it (modules then fall back to
    /// a generic Control Center symbol).
    private static func systemModuleNamesByPosition() -> [(CGFloat, String)] {
        guard CGPreflightScreenCaptureAccess() else { return [] }
        guard let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [(CGFloat, String)] = []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 25,
                  let name = info[kCGWindowName as String] as? String, !name.isEmpty, name != "Item-0",
                  let b = info[kCGWindowBounds as String],
                  let r = CGRect(dictionaryRepresentation: b as! CFDictionary) else { continue }
            out.append((r.minX, name))
        }
        return out
    }

    private static func moduleName(title: String?, pos: CGPoint, names: [(CGFloat, String)]) -> String? {
        if let title, !title.isEmpty { return title }
        if let near = names.min(by: { abs($0.0 - pos.x) < abs($1.0 - pos.x) }), abs(near.0 - pos.x) < 24 {
            return near.1
        }
        return nil
    }

    private static func systemSymbol(bundle: String?, title: String?, pos: CGPoint,
                                     names: [(CGFloat, String)]) -> String? {
        let isSystem = bundle == nil || bundle == "com.apple.controlcenter"
            || bundle == "com.apple.systemuiserver" || bundle == "com.apple.controlcenter.helper"
        guard isSystem else { return nil }
        let key = (moduleName(title: title, pos: pos, names: names) ?? title ?? "").lowercased()
        let map: [(String, String)] = [
            ("battery", "battery.100"),
            ("focus", "moon.fill"),
            ("timemachine", "clock.arrow.circlepath"),
            ("time machine", "clock.arrow.circlepath"),
            ("wifi", "wifi"),
            ("bluetooth", "dot.radiowaves.right"),
            ("clock", "clock"),
            ("sound", "speaker.wave.2.fill"),
            ("volume", "speaker.wave.2.fill"),
            ("display", "sun.max.fill"),
            ("nowplaying", "play.circle.fill"),
            ("now playing", "play.circle.fill"),
            ("airplay", "airplay.video"),
            ("screenmirroring", "airplay.video"),
            ("screen mirroring", "airplay.video"),
            ("keyboard", "keyboard"),
            ("textinput", "globe"),
            ("input", "globe"),
            ("spotlight", "magnifyingglass"),
            ("accessibility", "accessibility"),
            ("vpn", "lock.shield"),
            ("user", "person.crop.circle"),
        ]
        if let hit = map.first(where: { key.contains($0.0) })?.1 { return hit }
        return "switch.2" // generic Control Center glyph
    }

    // MARK: - AX value readers

    private static func axPoint(_ element: AXUIElement, _ attr: String) -> CGPoint {
        var ref: CFTypeRef?
        var point = CGPoint.zero
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
           let v = ref, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgPoint, &point)
        }
        return point
    }

    private static func axSize(_ element: AXUIElement, _ attr: String) -> CGSize {
        var ref: CFTypeRef?
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
           let v = ref, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgSize, &size)
        }
        return size
    }

    private static func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success {
            return (ref as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return nil
    }
}
