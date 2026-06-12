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
    /// Live screenshot of the item, when Screen Recording permission is granted.
    var image: NSImage?
}

enum MenuBarItemService {
    private static let statusItemWindowLayer = 25 // kCGStatusWindowLevel

    /// Hidden status items, enumerated while Tuck is collapsed — no need to
    /// expand the bar: the huge separator has already pushed them off-screen
    /// to negative x, where they are still listed by CGWindowList.
    static func hiddenItemsWhileCollapsed() -> [BarItem] {
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
            // Hidden items sit entirely off the left screen edge.
            guard rect.maxX < 0 else { continue }

            let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
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

    /// Capture live previews for the given items via ScreenCaptureKit.
    /// Window-based capture works even while the items are pushed off-screen,
    /// so the bar never has to expand for the panel. Items keep `image == nil`
    /// when capture is unavailable.
    ///
    /// Deliberately does NOT gate on CGPreflightScreenCaptureAccess: on
    /// macOS 26 the preflight can report false negatives, so we always try
    /// and let the result speak for itself.
    static func captureImages(for items: [BarItem]) async -> [BarItem] {
        guard !items.isEmpty else { return items }
        // onScreenWindowsOnly must be false: menu bar item windows are always
        // reported as off-screen on macOS 26.
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else {
            return items
        }

        var result: [BarItem] = []
        for var item in items {
            if let scWindow = content.windows.first(where: { $0.windowID == item.id }) {
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                config.width = Int(item.frame.width * 2)
                config.height = Int(item.frame.height * 2)
                config.showsCursor = false
                config.captureResolution = .best
                if let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    item.image = NSImage(cgImage: cgImage, size: item.frame.size)
                }
            }
            result.append(item)
        }
        return result
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
