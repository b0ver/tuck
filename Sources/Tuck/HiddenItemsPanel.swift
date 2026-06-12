import AppKit
import SwiftUI

/// Apple-style drop-down panel (blurred, rounded, shadowed — like a Control
/// Center module) that shows the hidden status items as clickable previews.
final class HiddenItemsPanelController: NSObject {
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?

    var isShown: Bool { panel?.isVisible ?? false }

    func show(from controller: StatusBarController) {
        Task { @MainActor in
            await self.loadAndShow(controller: controller)
        }
    }

    @MainActor
    private func loadAndShow(controller: StatusBarController) async {
        // The hidden items are off-screen while collapsed, so briefly expand
        // to enumerate and screenshot them, then collapse back.
        let wasCollapsed = controller.isCollapsed
        if wasCollapsed {
            controller.expand(startAutoCollapseTimer: false)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        let hidden = MenuBarItemService.hiddenItems(leftOf: controller.separatorScreenX)
        let items = await MenuBarItemService.captureImages(for: hidden)

        if wasCollapsed {
            controller.collapse()
        }

        presentPanel(items: items, controller: controller)
    }

    @MainActor
    private func presentPanel(items: [BarItem], controller: StatusBarController) {
        close()

        let view = HiddenItemsPanelView(items: items) { [weak self, weak controller] item in
            self?.close()
            controller?.forwardClick(to: item)
        }

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
}

// MARK: - SwiftUI content

struct HiddenItemsPanelView: View {
    let items: [BarItem]
    let onClick: (BarItem) -> Void

    var body: some View {
        Group {
            if items.isEmpty {
                Text(L("panel.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260)
                    .multilineTextAlignment(.center)
                    .padding(14)
            } else {
                HStack(spacing: 2) {
                    ForEach(items) { item in
                        PanelIconButton(item: item) { onClick(item) }
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
        .help(item.appName)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        if let image = item.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let icon = item.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}
