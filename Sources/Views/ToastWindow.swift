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

        let pad: CGFloat = 14
        let iconSize: CGFloat = 28
        let gap: CGFloat = 10

        // 量文本宽（自适应）
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: RuneFont.appKit(size: 13, weight: .semibold)
        ]
        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: RuneFont.appKit(size: 11)
        ]
        let titleW = (title as NSString).size(withAttributes: titleAttrs).width
        let msgW = (message as NSString).size(withAttributes: msgAttrs).width
        let minimumTextWidth: CGFloat = 150
        let maximumTextWidth: CGFloat = 310
        let textW = min(max(max(titleW, msgW) + 8, minimumTextWidth), maximumTextWidth)
        let messageBounds = (message as NSString).boundingRect(
            with: NSSize(width: textW, height: 40),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: msgAttrs
        )
        let messageHeight = min(30, max(15, ceil(messageBounds.height)))
        let panelW = pad * 2 + iconSize + gap + textW
        let panelH = max(58, pad * 2 + 17 + 3 + messageHeight)

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

        // 与 Rune 其余结果卡一致的浅色材质；错误和成功都靠图标表达，不整块变色。
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor
        panel.contentView = effect

        let iconView = NSImageView(frame: NSRect(
            x: pad, y: (panelH - iconSize) / 2, width: iconSize, height: iconSize
        ))
        iconView.image = iconImage
        iconView.contentTintColor = RuneTheme.nsAccent
        effect.addSubview(iconView)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = RuneFont.appKit(size: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.frame = NSRect(
            x: pad + iconSize + gap,
            y: panelH - pad - 17,
            width: textW,
            height: 17
        )
        effect.addSubview(titleField)

        let msgField = NSTextField(labelWithString: message)
        msgField.font = RuneFont.appKit(size: 11)
        msgField.textColor = .secondaryLabelColor
        msgField.lineBreakMode = .byCharWrapping
        msgField.maximumNumberOfLines = 2
        msgField.frame = NSRect(
            x: pad + iconSize + gap,
            y: pad,
            width: textW,
            height: messageHeight
        )
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
