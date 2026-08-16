import AppKit

/// 轻量顶部提示（Toast）。
///
/// 纯 AppKit 实现（NSVisualEffectView + NSTextField），不用 NSHostingView：
/// 实测 SwiftUI 宿主版在 OCR 等快节奏流程必现约束崩溃
/// （NSHostingView 布局更新撞窗口销毁，macOS 15 断言），纯 AppKit 根治。
@MainActor
final class ToastWindow {
    static let shared = ToastWindow()

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(
        title: String = "已保存",
        message: String,
        icon: NSImage? = nil,
        systemIcon: String? = nil,
        duration: TimeInterval = 2.5,
        on preferredScreen: NSScreen? = nil
    ) {
        dismissNow()

        // 图标：优先调用方给的图片，否则 SF 符号
        let iconImage: NSImage
        if let icon {
            iconImage = icon
        } else if let symbol = NSImage(
            systemSymbolName: systemIcon ?? "info.circle",
            accessibilityDescription: nil
        ) {
            iconImage = symbol
        } else {
            iconImage = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)!
        }

        let pad: CGFloat = 16
        let iconSize: CGFloat = 30
        let gap: CGFloat = 12

        // 量文本宽（自适应）
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]
        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11)
        ]
        let titleW = (title as NSString).size(withAttributes: titleAttrs).width
        let msgW = (message as NSString).size(withAttributes: msgAttrs).width
        let textW = max(titleW, msgW)
        let panelW = pad * 2 + iconSize + gap + textW + 4
        let panelH: CGFloat = 56

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 磨砂圆角底
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        panel.contentView = effect

        let iconView = NSImageView(frame: NSRect(
            x: pad, y: (panelH - iconSize) / 2, width: iconSize, height: iconSize
        ))
        iconView.image = iconImage
        iconView.contentTintColor = .white
        effect.addSubview(iconView)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .white
        titleField.frame = NSRect(x: pad + iconSize + gap, y: 28, width: textW + 4, height: 18)
        effect.addSubview(titleField)

        let msgField = NSTextField(labelWithString: message)
        msgField.font = .systemFont(ofSize: 11)
        msgField.textColor = NSColor.white.withAlphaComponent(0.72)
        msgField.frame = NSRect(x: pad + iconSize + gap, y: 10, width: textW + 4, height: 15)
        effect.addSubview(msgField)

        guard let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let sf = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: sf.midX - panelW / 2, y: sf.maxY - panelH - 12))
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.dismissNow()
        }
    }

    private func dismissNow() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func dismiss(animated: Bool) {
        dismissNow()
    }
}
