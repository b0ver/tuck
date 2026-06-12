import AppKit
import SwiftUI

/// Apple-style drop-down panel (blurred, rounded, shadowed — like a Control
/// Center module) that shows the hidden status items as clickable previews.
final class HiddenItemsPanelController: NSObject {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    var isShown: Bool { panel?.isVisible ?? false }

    /// Must be called while the bar is collapsed. Previews come from the
    /// controller's cache (snapshotted while the icons were visible); if the
    /// cache has nothing for the current items — e.g. Screen Recording was
    /// granted only after launch — self-heal with one brief expand/collapse.
    func show(from controller: StatusBarController) {
        Task { @MainActor in
            var items = MenuBarItemService.hiddenItemsWhileCollapsed()

            func applyCache() -> Bool {
                var any = false
                items = items.map { item in
                    var item = item
                    item.image = controller.previewCache[item.id]
                    any = any || item.image != nil
                    return item
                }
                return any
            }

            if !applyCache() && !items.isEmpty {
                controller.expand(startAutoCollapseTimer: false)
                try? await Task.sleep(nanoseconds: 400_000_000)
                await controller.refreshPreviewCache()
                controller.collapseWithoutCapture()
                try? await Task.sleep(nanoseconds: 250_000_000)
                items = MenuBarItemService.hiddenItemsWhileCollapsed()
                _ = applyCache()
            }

            // Pinned icons already live next to the Tuck button as proxies.
            items.removeAll { controller.pins.isPinned($0) }

            self.presentPanel(items: items, controller: controller)
        }
    }

    @MainActor
    private func presentPanel(items: [BarItem], controller: StatusBarController) {
        close()

        // Only claim a permission problem when nothing could be captured at
        // all — the preflight API alone is not trustworthy on macOS 26.
        let needsPermission = !items.isEmpty
            && items.allSatisfy { $0.image == nil }

        let view = HiddenItemsPanelView(
            items: items,
            iconsPerRow: Prefs.shared.panelIconsPerRow,
            needsPermission: needsPermission,
            onClick: { [weak self, weak controller] item in
                self?.close()
                controller?.forwardClick(to: item)
            },
            onPin: { [weak self, weak controller] item in
                self?.close()
                controller?.pins.pin(item)
            },
            onGrantPermission: { [weak self] in
                self?.close()
                CGRequestScreenCaptureAccess()
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                NSWorkspace.shared.open(url)
            },
            onRestart: {
                Self.relaunchApp()
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize

        let effect = NSVisualEffectView(frame: hosting.frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.addSubview(hosting)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: effect.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = effect
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false

        // Position: under the Tuck icon, right-aligned, like Control Center.
        if let anchor = controller.toggleItem.button?.window {
            let anchorFrame = anchor.frame
            let screen = anchor.screen ?? NSScreen.main
            var x = anchorFrame.maxX - panel.frame.width
            if let screen {
                x = min(x, screen.visibleFrame.maxX - panel.frame.width - 8)
                x = max(x, screen.visibleFrame.minX + 8)
            }
            let y = anchorFrame.minY - panel.frame.height - 6
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        self.panel = panel

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    /// Screen Recording permission only takes effect after a relaunch.
    private static func relaunchApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}

// MARK: - SwiftUI content

struct HiddenItemsPanelView: View {
    let items: [BarItem]
    let iconsPerRow: Int
    let needsPermission: Bool
    let onClick: (BarItem) -> Void
    let onPin: (BarItem) -> Void
    let onGrantPermission: () -> Void
    let onRestart: () -> Void

    private var rows: [[BarItem]] {
        let perRow = max(1, iconsPerRow)
        return stride(from: 0, to: items.count, by: perRow).map {
            Array(items[$0..<min($0 + perRow, items.count)])
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                Text(L("panel.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
                    .multilineTextAlignment(.center)
                    .padding(14)
            } else if needsPermission {
                VStack(spacing: 8) {
                    Text(L("panel.permission"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 250)
                        .multilineTextAlignment(.center)
                    Button(L("panel.permission.button"), action: onGrantPermission)
                        .controlSize(.small)
                    Button(L("panel.permission.restart"), action: onRestart)
                        .controlSize(.small)
                }
                .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 2) {
                            ForEach(row) { item in
                                PanelIconButton(
                                    item: item,
                                    action: { onClick(item) },
                                    pinAction: { onPin(item) }
                                )
                            }
                        }
                    }
                }
                .padding(7)
            }
        }
    }
}

private struct PanelIconButton: View {
    let item: BarItem
    let action: () -> Void
    let pinAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            iconView
                .frame(height: 24)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.12 : 0))
                )
        }
        .buttonStyle(.plain)
        .help(item.title ?? "")
        .onHover { hovering = $0 }
        .contextMenu {
            Button(action: pinAction) {
                Label(L("pin.pin"), systemImage: "pin")
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }
}
