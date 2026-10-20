import AppKit
import SwiftUI

/// 滚动长图跑完后的"结果条"（飞书同款）。
///
/// 飞书的长图结束画面上直接给四个动作：编辑 / 下载 / 取消 / 保存到剪贴板，
/// 长图预览就贴在旁边，不把用户丢回确认台再点一次。Rune 之前一律走确认台：
/// 多一步不说，几千像素高的长图在确认台里几乎没法操作。
@MainActor
final class ScrollCaptureResultBarController {
    static let shared = ScrollCaptureResultBarController()

    /// 结果条的四个动作。由编排器注入——面板只管长什么样，不管存哪。
    struct Actions {
        var edit: () -> Void
        var download: () -> Void
        var cancel: () -> Void
        var copyToClipboard: () -> Void
    }

    private var panel: NSPanel?

    private init() {}

    func show(image: CGImage, on screen: NSScreen?, actions: Actions) {
        dismiss()
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }

        let root = ScrollCaptureResultView(
            image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)),
            onEdit: actions.edit,
            onDownload: actions.download,
            onCancel: actions.cancel,
            onCopy: actions.copyToClipboard
        )
        .runeTypography()

        let size = CGSize(width: 360, height: 520)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // 与滚动截图的浮层同一层级：目标应用在前台时也要能看见。
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = host

        let visible = target.visibleFrame
        panel.setFrameOrigin(
            NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2
            )
        )
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

/// 结果条本体：上面是长图预览，下面是四个动作。
/// 预览按可用高度缩放，几千像素的长图也能一眼看全。
private struct ScrollCaptureResultView: View {
    let image: NSImage
    let onEdit: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void

    private let previewBox = CGSize(width: 330, height: 400)

    var body: some View {
        VStack(spacing: 12) {
            preview
            actions
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: previewBox.width, height: previewBox.height)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .frame(width: previewBox.width, height: previewBox.height)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            resultButton(title: "编辑", systemImage: "pencil", action: onEdit)
            resultButton(title: "下载", systemImage: "arrow.down.to.line", action: onDownload)
            resultButton(title: "取消", systemImage: "xmark", action: onCancel)
            resultButton(title: "保存到剪贴板", systemImage: "doc.on.doc", action: onCopy, isPrimary: true)
        }
    }

    private func resultButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void,
        isPrimary: Bool = false
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isPrimary ? Color.black.opacity(0.86) : Color.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isPrimary ? RuneTheme.cyan : Color.white.opacity(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
