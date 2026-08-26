import AppKit
import SwiftUI

@MainActor
final class MenuBarPopoverController: NSObject {
    static let shared = MenuBarPopoverController()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private(set) var isOpen = false
    private var eventMonitor: Any?

    var originScreen: NSScreen? {
        statusItem?.button?.window?.screen
    }

    private override init() { super.init() }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            button.image = NSImage(named: "MenuBarIcon")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        statusItem = item

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openAuditPopover()
            }
        }
        #endif
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if isOpen {
            closePopover()
        } else {
            openPopover()
        }
    }

    /// 打开菜单弹窗（供视觉自检 --audit-menu-style 调用）。
    func openPopover() {
        guard let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        let panelWidth = panel.frame.width
        let panelX = screenRect.midX - panelWidth / 2
        let panelY = screenRect.minY - panel.frame.height

        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isOpen = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }

        startEventMonitor()
    }

    #if DEBUG
    private func openAuditPopover() {
        if panel == nil {
            createPanel()
        }
        guard let panel, let screen = NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let panelX = visibleFrame.midX - panel.frame.width / 2
        let panelY = visibleFrame.maxY - panel.frame.height - 24
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        panel.alphaValue = 1
        if ProcessInfo.processInfo.arguments.contains("--audit-menu-interactive") {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        isOpen = true
        DebugAuditSnapshot.captureAfter("20-menu-complete-redesign.png")
    }
    #endif

    func closePopover() {
        guard let panel, isOpen else { return }
        isOpen = false
        stopEventMonitor()

        let closingPanel = panel
        self.panel = nil

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            closingPanel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                closingPanel.orderOut(nil)
                closingPanel.contentView = nil
            }
        })
    }

    private func createPanel() {
        let dismiss: @MainActor () -> Void = { [weak self] in
            self?.closePopover()
        }

        let contentView = MenuBarPanelView(dismissPopover: dismiss)
        let hostingView = NSHostingView(rootView: contentView.runeTypography())
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.contentView = hostingView
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.panel = panel
    }

    private func startEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closePopover()
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--audit-menu-interactive")
        #else
        false
        #endif
    }
}
