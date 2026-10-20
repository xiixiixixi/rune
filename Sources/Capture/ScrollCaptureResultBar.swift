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

        let size = CGSize(width: 404, height: 620)
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

/// 结果条本体：上面是可缩放的长图预览，下面是四个动作。
///
/// 预览默认按"铺满预览框宽度"显示——长图有几千像素高，缩到整个塞进框里
/// 只会剩一条看不清的细缝。往下滚动读内容，想看全貌再点「全览」缩回去。
/// 放大到 100% 就是原始像素，标注文字看得清。
private struct ScrollCaptureResultView: View {
    let image: NSImage
    let onEdit: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void
    let onCopy: () -> Void

    private let previewBox = CGSize(width: 376, height: 452)

    /// 缩放倍数：以"铺满预览框宽度"为 1.0。
    @State private var scale: Double = 1.0

    /// 铺满宽度时的比例。
    private var fitWidthScale: Double {
        guard image.size.width > 0 else { return 1 }
        return previewBox.width / image.size.width
    }

    /// 缩到最小 = 整张图完整塞进预览框（一眼看全）。
    private var minScale: Double {
        guard image.size.width > 0, image.size.height > 0 else { return 0.2 }
        let fitHeight = previewBox.height / image.size.height
        return min(1, fitHeight / fitWidthScale)
    }

    /// 放到最大 = 1:1 原始像素（再放大也没有新信息了）。
    private var maxScale: Double {
        guard image.size.width > 0 else { return 8 }
        return min(8, 1 / fitWidthScale)
    }

    private var effectiveScale: Double {
        min(max(scale, minScale), maxScale)
    }

    private var displayedSize: CGSize {
        let factor = fitWidthScale * effectiveScale
        return CGSize(
            width: image.size.width * factor,
            height: image.size.height * factor
        )
    }

    /// 相对原始像素的百分比（1:1 = 100%）。
    private var percentText: String {
        guard image.size.width > 0 else { return "100%" }
        let ratio = displayedSize.width / image.size.width
        return "\(Int((ratio * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 10) {
            zoomBar
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

    // MARK: - 缩放条

    private var zoomBar: some View {
        HStack(spacing: 6) {
            zoomButton(
                systemImage: "minus",
                label: "缩小",
                enabled: effectiveScale > minScale + 0.001
            ) {
                setScale(effectiveScale / 1.4)
            }
            Text(percentText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 46)
            zoomButton(
                systemImage: "plus",
                label: "放大",
                enabled: effectiveScale < maxScale - 0.001
            ) {
                setScale(effectiveScale * 1.4)
            }
            Button(action: { setScale(minScale) }) {
                Text("全览")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("缩到能看全整张长图")
            .accessibilityLabel("全览")
            Spacer(minLength: 0)
        }
    }

    private func zoomButton(
        systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.white.opacity(0.85) : Color.white.opacity(0.28))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    private func setScale(_ value: Double) {
        scale = min(max(value, minScale), maxScale)
    }

    // MARK: - 预览

    private var preview: some View {
        ScrollView([.vertical, .horizontal]) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: displayedSize.width, height: displayedSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                .padding(8)
        }
        .frame(width: previewBox.width, height: previewBox.height)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .help("滚轮上下滚动查看长图内容")
    }

    // MARK: - 动作

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
