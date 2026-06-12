import AppKit
import ScreenCaptureKit

/// A status item living in the menu bar.
///
/// Note for macOS 26+: every menu bar item window is owned by the Control
/// Center process, not by the app that created it, and all of them are
/// reported as off-screen by CGWindowList. So we enumerate without the
/// on-screen filter and identify hidden items purely by geometry: while Tuck
/// is collapsed, the expanded separator pushes them to strongly negative x.
struct BarItem: Identifiable {
    let id: CGWindowID
    /// Global display coordinates (top-left origin), as reported by CGWindowList.
    let frame: CGRect
    /// Window title if readable (requires Screen Recording permission).
    let title: String?
    /// Live screenshot of the item, when the system lets us capture one.
    var image: NSImage?
    /// Owning app, resolved via the Accessibility API (AXExtrasMenuBar).
    var appPID: pid_t?
    var appBundleID: String?
    var appName: String?
    /// AX title/description of the item, e.g. "Battery", "FocusModes".
    var axTitle: String?

    var isControlCenterOwned: Bool { appBundleID == "com.apple.controlcenter" }

    var displayTitle: String {
        if let axTitle, !axTitle.isEmpty { return axTitle }
        if let appName, !appName.isEmpty { return appName }
        if let title, !title.isEmpty, title != "Item-0" { return title }
        return "?"
    }

    var appIcon: NSImage? {
        guard let appPID else { return nil }
        return NSRunningApplication(processIdentifier: appPID)?.icon
    }

    /// Best identification image when no live screenshot is available:
    /// the owning app's icon, or an SF Symbol for Control Center modules.
    var fallbackIcon: NSImage? {
        if !isControlCenterOwned, let icon = appIcon { return icon }
        if let symbol = Self.symbolName(matching: displayTitle),
           let img = NSImage(systemSymbolName: symbol, accessibilityDescription: displayTitle) {
            return img.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }
        return appIcon
    }

    private static func symbolName(matching title: String) -> String? {
        let t = title.lowercased()
        let map: [(String, String)] = [
            ("battery", "battery.100"),
            ("focusmodes", "moon.fill"),
            ("focus", "moon.fill"),
            ("timemachine", "clock.arrow.circlepath"),
            ("wifi", "wifi"),
            ("bluetooth", "logo.bluetooth" ),
            ("clock", "clock"),
            ("sound", "speaker.wave.2.fill"),
            ("audio", "speaker.wave.2.fill"),
            ("display", "sun.max.fill"),
            ("nowplaying", "play.circle.fill"),
            ("airplay", "airplay.video"),
            ("screenmirroring", "airplay.video"),
            ("keyboardbrightness", "light.max"),
            ("accessibility", "accessibility"),
            ("usermenu", "person.crop.circle"),
            ("vpn", "lock.shield"),
        ]
        return map.first { t.contains($0.0) }?.1
    }
}

enum MenuBarItemService {
    private static let statusItemWindowLayer = 25 // kCGStatusWindowLevel

    /// Hidden status items, enumerated while Tuck is collapsed — no need to
    /// expand the bar: the huge separator has already pushed them off-screen
    /// to negative x, where they are still listed by CGWindowList.
    static func hiddenItemsWhileCollapsed() -> [BarItem] {
        menuBarItems().filter { $0.frame.maxX < 0 }
    }

    /// Status items currently visible on screen (positive x).
    static func visibleItems() -> [BarItem] {
        menuBarItems().filter { $0.frame.minX >= 0 }
    }

    private static func menuBarItems() -> [BarItem] {
        guard let list = CGWindowListCopyWindowInfo([], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var items: [BarItem] = []
        for info in list {
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == statusItemWindowLayer,
                let boundsDict = info[kCGWindowBounds as String],
                let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
            else { continue }

            // Menu bar geometry only.
            guard rect.minY <= 1, (20...40).contains(rect.height) else { continue }
            // Skip our own giant separator and any other oversized window.
            guard rect.width <= 600 else { continue }

            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // Skip Tuck's own items (toggle, separator, pinned proxies) —
            // their window titles carry our autosave names.
            if let title, title.hasPrefix("tuck.") { continue }
            items.append(BarItem(id: CGWindowID(info[kCGWindowNumber as String] as? Int ?? 0),
                                 frame: rect, title: title, image: nil))
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Fresh frame of a status item window (it moves when the bar expands).
    static func currentFrame(of windowID: CGWindowID) -> CGRect? {
        guard
            let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
            let info = list.first,
            let boundsDict = info[kCGWindowBounds as String],
            let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
        else { return nil }
        return rect
    }

    // MARK: - Screenshots

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    // NOTE: per-window capture is a dead end on macOS 26 — ScreenCaptureKit's
    // desktopIndependentWindow filter fails with SCStreamError -3811, and the
    // private SLSHWCaptureWindowList returns fully transparent images for menu
    // bar item windows (their content is composited by Control Center).
    // Capturing the menu bar strip of the display and slicing it is the only
    // path that works; it requires the items to be on screen.

    /// Capture previews of the currently visible status items by photographing
    /// the menu bar strip of the main display once and slicing it per item.
    ///
    /// Per-window ScreenCaptureKit capture fails for menu bar item windows on
    /// macOS 26 (SCStreamError -3811), so display capture is the only reliable
    /// path. It can only see on-screen items, which is why the cache is built
    /// while the bar is expanded (at launch and right before each collapse).
    ///
    /// Deliberately does NOT gate on CGPreflightScreenCaptureAccess: on
    /// macOS 26 the preflight can report false negatives, so we always try
    /// and let the result speak for itself.
    static func capturePreviews(of items: [BarItem]) async -> [CGWindowID: NSImage] {
        let onScreen = items.filter { $0.frame.minX >= 0 }
        TuckLog.log("capture: requested=\(items.count) onScreen=\(onScreen.count) " +
                    "items=\(items.map { "(id:\($0.id) x:\(Int($0.frame.minX)) w:\(Int($0.frame.width)))" }.joined(separator: " "))")
        guard !onScreen.isEmpty else { return [:] }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
        else {
            TuckLog.log("capture: SCShareableContent FAILED (permission?)")
            return [:]
        }

        let displayWidth = CGFloat(display.width)
        let stripHeight = (onScreen.map { $0.frame.maxY }.max() ?? 30) + 2
        let scale: CGFloat = 2

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: displayWidth, height: stripHeight)
        config.width = Int(displayWidth * scale)
        config.height = Int(stripHeight * scale)
        config.showsCursor = false
        config.captureResolution = .best

        guard let strip = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            TuckLog.log("capture: strip capture FAILED (display \(display.displayID), w=\(display.width))")
            return [:]
        }
        TuckLog.log("capture: strip \(strip.width)x\(strip.height)px displayWidth=\(Int(displayWidth))pt stripHeight=\(Int(stripHeight))pt")
        TuckLog.dump(strip, name: "strip-\(Int(Date().timeIntervalSince1970))")

        let actualScale = CGFloat(strip.width) / displayWidth
        var previews: [CGWindowID: NSImage] = [:]
        for item in onScreen {
            let pixelRect = CGRect(
                x: item.frame.minX * actualScale,
                y: item.frame.minY * actualScale,
                width: item.frame.width * actualScale,
                height: item.frame.height * actualScale
            ).integral
            guard let crop = strip.cropping(to: pixelRect) else {
                TuckLog.log("capture: id=\(item.id) x=\(Int(item.frame.minX)) CROP FAILED rect=\(pixelRect)")
                continue
            }
            // Items that did not fit in the menu bar (e.g. tucked under the
            // notch) have valid frames but render nothing — a uniform slice.
            // Skipping them keeps stale-but-real previews in the cache.
            guard !isUniformSlice(crop) else {
                TuckLog.log("capture: id=\(item.id) x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) UNIFORM slice, skipped")
                TuckLog.dump(crop, name: "uniform-\(item.id)")
                continue
            }
            TuckLog.log("capture: id=\(item.id) x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) OK")
            TuckLog.dump(crop, name: "ok-\(item.id)")
            previews[item.id] = NSImage(cgImage: crop, size: item.frame.size)
        }
        TuckLog.log("capture: result \(previews.count)/\(onScreen.count)")
        return previews
    }

    /// True when the image is (nearly) a solid color — i.e. an empty slice.
    private static func isUniformSlice(_ image: CGImage) -> Bool {
        let w = 12, h = 12
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let minVal = pixels.min(), let maxVal = pixels.max() else { return false }
        return maxVal - minVal < 12
    }

    // MARK: - Owning app resolution (Accessibility API)

    /// Resolve which app owns each status item by walking every running
    /// app's AXExtrasMenuBar and matching items by x-coordinate. Works for
    /// off-screen (hidden) items too — AX reports the same shifted frames.
    /// Requires Accessibility permission; returns items unchanged without it.
    static func annotateWithApps(_ items: [BarItem]) -> [BarItem] {
        guard AXIsProcessTrusted(), !items.isEmpty else {
            if !items.isEmpty { TuckLog.log("annotate: AX not trusted, skipping") }
            return items
        }

        struct Extra {
            let x: CGFloat
            let width: CGFloat
            let title: String?
            let pid: pid_t
            let bundle: String?
            let name: String?
        }

        var extras: [Extra] = []
        for app in NSWorkspace.shared.runningApplications {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            var barRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &barRef) == .success,
                  let barRef, CFGetTypeID(barRef) == AXUIElementGetTypeID()
            else { continue }
            let bar = unsafeDowncast(barRef, to: AXUIElement.self)

            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement]
            else { continue }

            for kid in kids {
                var pos = CGPoint.zero
                var size = CGSize.zero
                var ref: CFTypeRef?
                if AXUIElementCopyAttributeValue(kid, kAXPositionAttribute as CFString, &ref) == .success,
                   let v = ref, CFGetTypeID(v) == AXValueGetTypeID() {
                    AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgPoint, &pos)
                }
                ref = nil
                if AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &ref) == .success,
                   let v = ref, CFGetTypeID(v) == AXValueGetTypeID() {
                    AXValueGetValue(unsafeDowncast(v, to: AXValue.self), .cgSize, &size)
                }
                var title: String?
                ref = nil
                if AXUIElementCopyAttributeValue(kid, kAXTitleAttribute as CFString, &ref) == .success {
                    title = ref as? String
                }
                if title?.isEmpty != false {
                    ref = nil
                    if AXUIElementCopyAttributeValue(kid, kAXDescriptionAttribute as CFString, &ref) == .success {
                        title = ref as? String
                    }
                }
                extras.append(Extra(x: pos.x, width: size.width, title: title,
                                    pid: app.processIdentifier,
                                    bundle: app.bundleIdentifier,
                                    name: app.localizedName))
            }
        }
        TuckLog.log("annotate: AX extras=\(extras.count) for items=\(items.count)")

        return items.map { item in
            var item = item
            if let match = extras.min(by: { abs($0.x - item.frame.minX) < abs($1.x - item.frame.minX) }) {
                if abs(match.x - item.frame.minX) < 8 {
                    item.appPID = match.pid
                    item.appBundleID = match.bundle
                    item.appName = match.name
                    if let t = match.title, !t.isEmpty { item.axTitle = t }
                } else {
                    TuckLog.log("annotate: NO MATCH for item x=\(Int(item.frame.minX)) w=\(Int(item.frame.width)) — nearest extra x=\(Int(match.x)) (\(match.name ?? "?"))")
                }
            }
            return item
        }
    }

    // MARK: - Item identity (for pinning)

    /// Best-effort stable keys for status items across app launches, keyed by
    /// window id. Prefers the owning app's bundle id (with an ordinal for
    /// apps that own several items), then AX/window titles, then a perceptual
    /// hash of the snapshot.
    static func identityKeys(for items: [BarItem]) -> [CGWindowID: String] {
        var counters: [String: Int] = [:]
        var keys: [CGWindowID: String] = [:]
        for item in items.sorted(by: { $0.frame.minX < $1.frame.minX }) {
            let base: String
            if item.isControlCenterOwned, let ax = item.axTitle, !ax.isEmpty {
                base = "cc:" + ax
            } else if let bundle = item.appBundleID {
                base = "b:" + bundle
            } else if let title = item.title, !title.isEmpty, title != "Item-0" {
                base = "t:" + title
            } else if let image = item.image, let hash = averageHash(image) {
                keys[item.id] = "h:" + hash
                continue
            } else {
                base = "w:\(Int(item.frame.width.rounded()))"
            }
            let n = counters[base, default: 0]
            counters[base] = n + 1
            keys[item.id] = n == 0 ? base : "\(base)#\(n)"
        }
        return keys
    }

    /// Whether a candidate key matches a stored pin key. Hash keys compare
    /// fuzzily so a changing badge (e.g. an unread counter) keeps the pin.
    static func keysMatch(_ stored: String, _ candidate: String) -> Bool {
        if stored == candidate { return true }
        guard stored.hasPrefix("h:"), candidate.hasPrefix("h:"),
              let a = UInt64(stored.dropFirst(2), radix: 16),
              let b = UInt64(candidate.dropFirst(2), radix: 16)
        else { return false }
        return (a ^ b).nonzeroBitCount <= 12
    }

    /// 64-bit average hash of the image (8×8 grayscale, thresholded at mean).
    private static func averageHash(_ image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let average = pixels.reduce(0) { $0 + Int($1) } / (w * h)
        var bits: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) > average {
            bits |= (1 << UInt64(i))
        }
        return String(bits, radix: 16)
    }

    // MARK: - Click forwarding

    static var hasAccessibilityAccess: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Synthesize a click at a point in global display coordinates.
    static func postClick(at point: CGPoint, rightButton: Bool = false) {
        let source = CGEventSource(stateID: .hidSystemState)
        let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = rightButton ? .right : .left

        let down = CGEvent(mouseEventSource: source, mouseType: downType,
                           mouseCursorPosition: point, mouseButton: button)
        let up = CGEvent(mouseEventSource: source, mouseType: upType,
                         mouseCursorPosition: point, mouseButton: button)
        down?.post(tap: .cghidEventTap)
        usleep(60_000)
        up?.post(tap: .cghidEventTap)
    }
}
