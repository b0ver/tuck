import AppKit
import ScreenCaptureKit

/// A third-party status item living in the menu bar.
struct BarItem: Identifiable {
    let id: CGWindowID
    let pid: pid_t
    /// Global display coordinates (top-left origin), as reported by CGWindowList.
    let frame: CGRect
    let appName: String
    /// Live screenshot of the item, when Screen Recording permission is granted.
    var image: NSImage?

    var appIcon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

enum MenuBarItemService {
    private static let statusItemWindowLayer = 25 // kCGStatusWindowLevel

    /// All third-party status item windows on the main display, left to right.
    static func statusItems() -> [BarItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let mainScreen = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        guard let screen = mainScreen else { return [] }
        let screenWidth = screen.frame.width
        let ownPID = getpid()

        var items: [BarItem] = []
        for info in list {
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == statusItemWindowLayer,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let boundsDict = info[kCGWindowBounds as String],
                let rect = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary)
            else { continue }

            // Keep only items in the main display's menu bar.
            guard rect.minY <= 1, rect.height <= 40, rect.width <= 600 else { continue }
            guard rect.minX >= -50, rect.maxX <= screenWidth + 50 else { continue }

            let name = info[kCGWindowOwnerName as String] as? String ?? "?"
            items.append(BarItem(id: CGWindowID(info[kCGWindowNumber as String] as? Int ?? 0),
                                 pid: pid, frame: rect, appName: name, image: nil))
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Items the user dragged into the hidden section (left of the separator).
    /// Must be called while the bar is expanded.
    static func hiddenItems(leftOf separatorX: CGFloat) -> [BarItem] {
        statusItems().filter { $0.frame.midX < separatorX }
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
    /// Items keep `image == nil` when capture is unavailable.
    static func captureImages(for items: [BarItem]) async -> [BarItem] {
        guard hasScreenCaptureAccess, !items.isEmpty else { return items }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
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
