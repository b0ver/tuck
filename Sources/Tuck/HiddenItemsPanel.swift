import AppKit
import SwiftUI

/// Apple-style drop-down panel (blurred, rounded, shadowed — like a Control
/// Center module) that shows the hidden status items as clickable previews.
final class HiddenItemsPanelController: NSObject {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    var isShown: Bool { panel?.isVisible ?? false }
    private(set) var isPreparing = false

    /// Must be called while the bar is collapsed. Items are read live from the
    /// Accessibility API (the only reliable source on macOS 26).
    func show(from controller: StatusBarController) {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }

        var items = MenuBarItemService.hiddenItems()
        // Pinned icons already live next to the Tuck button as proxies.
        let pinned = Prefs.shared.pinnedItems
        items.removeAll { item in
            pinned.contains { MenuBarItemService.keysMatch($0, item.id) }
        }
        presentPanel(items: items, controller: controller)
    }

    private func presentPanel(items: [BarItem], controller: StatusBarController) {
        close()

        // Without Accessibility, items can't be enumerated at all.
        let needsPermission = !MenuBarItemService.hasAccessibilityAccess

        let view = HiddenItemsPanelView(
            items: items,
            iconsPerRow: Prefs.shared.panelIconsPerRow,
            needsPermission: needsPermission,
            onClick: { [weak self, weak controller] item in
                self?.close()
                controller?.forwardClick(to: item)
            },
            onRightClick: { [weak self, weak controller] item in
                self?.close()
                controller?.forwardClick(to: item, rightButton: true)
            },
            onGrantPermission: { [weak self] in
                self?.close()
                MenuBarItemService.requestAccessibilityAccess()
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
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

    /// Accessibility permission reliably takes effect after a relaunch.
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
    let onRightClick: (BarItem) -> Void
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
            if needsPermission {
                VStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 22))
                        .foregroundStyle(.tint)
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
                .padding(16)
            } else if items.isEmpty {
                Text(L("panel.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
                    .multilineTextAlignment(.center)
                    .padding(14)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 2) {
                            ForEach(row) { item in
                                PanelIconButton(
                                    item: item,
                                    action: { onClick(item) },
                                    rightAction: { onRightClick(item) }
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
    let rightAction: () -> Void
    @State private var hovering = false

    var body: some View {
        // Right-click forwards the app's own context menu, like in the real
        // menu bar; pinning is managed from Settings → Icons.
        RightClickable(onRightClick: rightAction) {
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
            .help(item.displayTitle)
            .onHover { hovering = $0 }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
    }
}

/// Hosts SwiftUI content inside an NSView that catches right clicks anywhere
/// over the content (SwiftUI has no native right-click gesture on macOS).
/// Left clicks are handled by the SwiftUI controls and never reach this view.
private struct RightClickable<Content: View>: NSViewRepresentable {
    let onRightClick: () -> Void
    @ViewBuilder let content: () -> Content

    init(onRightClick: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.onRightClick = onRightClick
        self.content = content
    }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.onRightClick = onRightClick
        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        container.host = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        (container.host as? NSHostingView<Content>)?.rootView = content()
        container.onRightClick = onRightClick
    }

    final class Container: NSView {
        var onRightClick: (() -> Void)?
        weak var host: NSView?

        override var intrinsicContentSize: NSSize {
            host?.fittingSize ?? .zero
        }

        override func rightMouseUp(with event: NSEvent) {
            onRightClick?()
        }
    }
}
