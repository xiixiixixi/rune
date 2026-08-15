import AppKit
import SwiftUI

// MARK: - PinnedScreenshotController

/// Manages multiple pinned screenshot floating windows.
@MainActor
final class PinnedScreenshotController {
    static let shared = PinnedScreenshotController()
    private var panels: [NSPanel] = []
    private init() {}

    var hasPinnedWindows: Bool {
        !panels.isEmpty
    }

    /// Creates a new borderless, always-on-top floating panel showing the image at `url`.
    func pin(url: URL, on preferredScreen: NSScreen? = nil) {
        guard let image = NSImage(contentsOf: url) else { return }

        // Compute initial panel size: scale image to max 400pt on longest side.
        let maxSide: CGFloat = 400
        let imgSize = image.size
        let scale: CGFloat
        if imgSize.width >= imgSize.height {
            scale = min(maxSide / imgSize.width, 1)
        } else {
            scale = min(maxSide / imgSize.height, 1)
        }
        let panelSize = CGSize(
            width: max(imgSize.width * scale, 80),
            height: max(imgSize.height * scale, 60)
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true

        let contentView = PinnedScreenshotView(
            image: image,
            originalDisplaySize: panelSize,
            onClose: { [weak self, weak panel] in
                guard let self, let panel else { return }
                panel.orderOut(nil)
                self.panels.removeAll { $0 === panel }
            }
        )
        panel.contentView = NSHostingView(rootView: contentView)

        if let screen = preferredScreen ?? NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - panelSize.width / 2 + CGFloat(panels.count) * 20
            let y = sf.midY - panelSize.height / 2 - CGFloat(panels.count) * 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panels.append(panel)
        panel.orderFront(nil)
    }

    /// Closes all pinned panels.
    func unpinAll() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

// MARK: - PinnedScreenshotView

/// SwiftUI content view for a single pinned screenshot panel.
struct PinnedScreenshotView: View {
    let image: NSImage
    let originalDisplaySize: CGSize
    let onClose: () -> Void

    @State private var scaleFactor: CGFloat = 1.0
    @State private var isHovered: Bool = false
    @State private var opacity: Double = 1.0           // P1 贴图增强：透明度
    @State private var clickThrough: Bool = false      // P1 贴图增强：鼠标穿透

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 4.0

    var body: some View {
        let w = originalDisplaySize.width * scaleFactor
        let h = originalDisplaySize.height * scaleFactor

        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: w, height: h)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                .opacity(opacity)   // P1：透明度
                .help("滚轮：缩放大小 ｜ 拖动：移动位置 ｜ 右键：透明度 / 鼠标穿透 / 关闭")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }

            // Close (X) button — visible on hover
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("关闭贴图")
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .frame(width: w, height: h)
        // 鼠标穿透时，让窗口忽略鼠标事件（点穿到后面的窗口）
        .background(MousePassthroughView(isPassthrough: clickThrough))
        // Resize via scroll wheel
        .onScrollWheel { delta in
            let newScale = (scaleFactor + delta * 0.05).clamped(to: minScale...maxScale)
            scaleFactor = newScale
            resizeWindow(to: CGSize(width: originalDisplaySize.width * newScale,
                                    height: originalDisplaySize.height * newScale))
        }
        // Right-click context menu（含透明度/穿透切换）
        .contextMenu {
            Button("复制图片") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.writeObjects([image])
            }
            Divider()
            // P1 贴图增强：透明度调节
            Slider(value: $opacity, in: 0.2...1.0, step: 0.1) {
                Text("透明度：\(Int(opacity * 100))%")
            }
            // P1 贴图增强：鼠标穿透切换
            Toggle("鼠标穿透", isOn: $clickThrough)
            Divider()
            Button("关闭") {
                onClose()
            }
        }
    }

    private func resizeWindow(to newSize: CGSize) {
        guard let window = NSApp.windows.first(where: {
            ($0.contentView as? NSHostingView<PinnedScreenshotView>) != nil
        }) ?? findHostingWindow() else { return }

        var frame = window.frame
        // Keep the top-left corner anchored.
        frame.origin.y += frame.size.height - newSize.height
        frame.size = newSize
        window.setFrame(frame, display: true, animate: false)
    }

    private func findHostingWindow() -> NSWindow? {
        // Walk all app windows to find the one hosting this view.
        for window in NSApp.windows {
            if let hv = window.contentView as? NSHostingView<PinnedScreenshotView> {
                // Check it's ours by comparing image size as a proxy.
                if hv.rootView.image.size == image.size {
                    return window
                }
            }
        }
        return nil
    }
}

// MARK: - Scroll-wheel modifier

private struct ScrollWheelModifier: ViewModifier {
    let handler: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            ScrollWheelView(handler: handler)
        )
    }
}

private struct ScrollWheelView: NSViewRepresentable {
    let handler: (CGFloat) -> Void

    func makeNSView(context: Context) -> _ScrollWheelNSView {
        let v = _ScrollWheelNSView()
        v.handler = handler
        return v
    }

    func updateNSView(_ nsView: _ScrollWheelNSView, context: Context) {
        nsView.handler = handler
    }
}

final class _ScrollWheelNSView: NSView {
    var handler: ((CGFloat) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.deltaY
        handler?(delta)
    }
}

private extension View {
    func onScrollWheel(_ handler: @escaping (CGFloat) -> Void) -> some View {
        modifier(ScrollWheelModifier(handler: handler))
    }
}

// MARK: - Comparable clamped helper (local, no collision risk)

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - 鼠标穿透（P1 贴图增强）

/// 控制 NSWindow 的 ignoresMouseEvents，实现"鼠标穿透"——贴图挡住下面窗口时，
/// 鼠标点击穿过去点后面的东西。配合 contextMenu 的 Toggle 用。
private struct MousePassthroughView: NSViewRepresentable {
    let isPassthrough: Bool

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.ignoresMouseEvents = isPassthrough
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.ignoresMouseEvents = isPassthrough
        }
    }
}
