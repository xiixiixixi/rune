import AppKit
import SwiftUI

// MARK: - PinnedScreenshotController

/// Manages multiple pinned screenshot floating windows.
@MainActor
@Observable
final class PinnedScreenshotController {
    static let shared = PinnedScreenshotController()

    private struct Session {
        let panel: NSPanel
        let interaction: PinnedScreenshotInteraction
    }

    private var sessions: [Session] = []
    private init() {}

    var hasPinnedWindows: Bool {
        !sessions.isEmpty
    }

    var hasPassthroughWindows: Bool {
        sessions.contains { $0.interaction.clickThrough }
    }

    /// Creates a new borderless, always-on-top floating panel showing the image at `url`.
    func pin(
        url: URL,
        on preferredScreen: NSScreen? = nil,
        auditShowsControls: Bool = false
    ) {
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

        let interaction = PinnedScreenshotInteraction()
        let contentView = PinnedScreenshotView(
            image: image,
            originalDisplaySize: panelSize,
            interaction: interaction,
            alwaysShowsControls: auditShowsControls,
            onClose: { [weak self, weak panel] in
                guard let self, let panel else { return }
                panel.orderOut(nil)
                self.sessions.removeAll { $0.panel === panel }
            }
        )
        panel.contentView = NSHostingView(rootView: contentView.runeTypography())

        if let screen = preferredScreen ?? NSScreen.main {
            let sf = screen.visibleFrame
            let x = sf.midX - panelSize.width / 2 + CGFloat(sessions.count) * 20
            let y = sf.midY - panelSize.height / 2 - CGFloat(sessions.count) * 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        sessions.append(Session(panel: panel, interaction: interaction))
        panel.orderFront(nil)
    }

    /// Closes all pinned panels.
    func unpinAll() {
        sessions.forEach { $0.panel.orderOut(nil) }
        sessions.removeAll()
    }

    /// 鼠标穿透开启后，贴图本身收不到点击；菜单栏提供统一恢复入口。
    func restoreInteractions() {
        for session in sessions {
            session.interaction.clickThrough = false
            session.panel.ignoresMouseEvents = false
        }
    }
}

@MainActor
@Observable
private final class PinnedScreenshotInteraction {
    var opacity: Double = 1.0
    var clickThrough = false
}

// MARK: - PinnedScreenshotView

/// SwiftUI content view for a single pinned screenshot panel.
private struct PinnedScreenshotView: View {
    let image: NSImage
    let originalDisplaySize: CGSize
    @Bindable var interaction: PinnedScreenshotInteraction
    let alwaysShowsControls: Bool
    let onClose: () -> Void

    @State private var scaleFactor: CGFloat = 1.0
    @State private var isHovered: Bool = false
    @State private var dragStartScale: CGFloat?        // 四角缩放：手势起始比例
    @State private var hostingWindow: NSWindow?

    private let minScale: CGFloat = 0.25
    private let maxScale: CGFloat = 4.0

    var body: some View {
        let w = originalDisplaySize.width * scaleFactor
        let h = originalDisplaySize.height * scaleFactor

        ZStack(alignment: .top) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: w, height: h)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                .opacity(interaction.opacity)
                .help("滚轮缩放，拖动移动；悬停可显示贴图工具条")
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }

            if (isHovered || alwaysShowsControls) && !interaction.clickThrough {
                pinToolbar
                    .padding(.top, 8)
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))

                ForEach(PinCorner.allCases, id: \.self) { corner in
                    cornerHandle(corner)
                }
            }

            if interaction.clickThrough {
                Text("鼠标穿透中 · 从 Rune 菜单恢复")
                    .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(.black.opacity(0.66), in: Capsule())
                    .padding(.top, 8)
            }
        }
        .frame(width: w, height: h)
        .background(
            PinnedWindowResolver { window in
                hostingWindow = window
            }
        )
        .background(MousePassthroughView(isPassthrough: interaction.clickThrough))
        .onScrollWheel { delta in
            let newScale = (scaleFactor + delta * 0.05).clamped(to: minScale...maxScale)
            setScale(newScale)
        }
        .contextMenu {
            Button("复制图片") {
                copyImage()
            }
            Divider()
            Slider(value: $interaction.opacity, in: 0.2...1.0, step: 0.1) {
                Text("透明度：\(Int(interaction.opacity * 100))%")
            }
            Button("开启鼠标穿透") {
                interaction.clickThrough = true
            }
            Divider()
            Button("关闭贴图", role: .destructive, action: onClose)
        }
    }

    private var pinToolbar: some View {
        HStack(spacing: 7) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(RuneTheme.accent)
                    .frame(width: 24, height: 24)
            }
            .help("关闭贴图")

            Divider()
                .frame(height: 18)

            Image(systemName: "circle.lefthalf.filled")
                .font(RuneFont.swiftUI(size: 10))
                .foregroundStyle(.secondary)

            Slider(value: $interaction.opacity, in: 0.2...1.0, step: 0.1)
                .frame(width: 62)
                .controlSize(.mini)
                .help("透明度 \(Int(interaction.opacity * 100))%")

            Menu {
                ForEach([0.5, 0.75, 1.0, 1.5, 2.0], id: \.self) { value in
                    Button("\(Int(value * 100))%") {
                        setScale(value)
                    }
                }
            } label: {
                Text("\(Int(scaleFactor * 100))%")
                    .font(RuneFont.swiftUI(size: 10, weight: .medium, design: .monospaced))
                    .frame(minWidth: 34)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("贴图大小")

            Button {
                copyImage()
            } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 24, height: 24)
            }
            .help("复制图片")

            Button {
                interaction.clickThrough = true
            } label: {
                Image(systemName: "cursorarrow.rays")
                    .frame(width: 24, height: 24)
            }
            .help("开启鼠标穿透；从 Rune 菜单恢复")
        }
        .font(RuneFont.swiftUI(size: 11, weight: .semibold))
        .buttonStyle(.plain)
        .foregroundStyle(.primary.opacity(0.78))
        .padding(.horizontal, 7)
        .frame(height: 34)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    /// 四角等比缩放手柄：拖动按原比例缩放（宽高等比，不会变形）。
    private func cornerHandle(_ corner: PinCorner) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.5), lineWidth: 1))
            .frame(width: 12, height: 12)
            .shadow(color: .black.opacity(0.3), radius: 2)
            .contentShape(Circle().inset(by: -6))
            .position(corner.point(in: CGSize(width: originalDisplaySize.width * scaleFactor,
                                              height: originalDisplaySize.height * scaleFactor)))
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        // 以"横向拖拽量 / 当前宽度"作缩放系数，等比应用到宽高
                        let currentW = originalDisplaySize.width * scaleFactor
                        let ratio = 1 + drag.translation.width / max(currentW, 60)
                        let base = dragStartScale ?? scaleFactor
                        dragStartScale = base
                        scaleFactor = min(max(base * ratio, minScale), maxScale)
                    }
                    .onEnded { _ in dragStartScale = nil }
            )
            .help("拖动按比例缩放贴图")
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }

    private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func setScale(_ newScale: CGFloat) {
        let clampedScale = newScale.clamped(to: minScale...maxScale)
        scaleFactor = clampedScale
        resizeWindow(to: CGSize(
            width: originalDisplaySize.width * clampedScale,
            height: originalDisplaySize.height * clampedScale
        ))
    }

    private func resizeWindow(to newSize: CGSize) {
        guard let window = hostingWindow else { return }

        var frame = window.frame
        // 缩放时固定左上角，画面不会突然跳到另一处。
        frame.origin.y += frame.size.height - newSize.height
        frame.size = newSize
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - 贴图四角

/// 四个缩放手柄的角位置。
enum PinCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    func point(in size: CGSize) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 10, y: size.height - 10)
        case .topRight: CGPoint(x: size.width - 10, y: size.height - 10)
        case .bottomLeft: CGPoint(x: 10, y: 10)
        case .bottomRight: CGPoint(x: size.width - 10, y: 10)
        }
    }
}

private struct PinnedWindowResolver: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
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
