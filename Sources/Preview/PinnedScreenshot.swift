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

    var pinnedCount: Int {
        sessions.count
    }

    var hasPassthroughWindows: Bool {
        sessions.contains { $0.interaction.clickThrough }
    }
    /// Creates a new borderless, always-on-top floating panel showing the image at `url`.
    func pin(
        url: URL,
        on preferredScreen: NSScreen? = nil,
        placement: PinnedPlacement = .center,
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
        // 移动窗口不交给系统的"拖背景即移动"：它会抢走四角缩放手势的鼠标事件，
        // 导致拖角缩放失效。移动改由 PinnedScreenshotView 的拖拽手势自己实现。

        let interaction = PinnedScreenshotInteraction()
        interaction.baseSize = panelSize
        let contentView = PinnedScreenshotView(
            image: image,
            sourceURL: url,
            interaction: interaction,
            alwaysShowsControls: auditShowsControls,
            onClose: { [weak self, weak panel] in
                guard let self, let panel else { return }
                panel.orderOut(nil)
                self.sessions.removeAll { $0.panel === panel }
                self.teardownMonitorIfNeeded()
            }
        )
        panel.contentView = NSHostingView(rootView: contentView.runeTypography())

        if let screen = preferredScreen ?? NSScreen.main {
            let sf = screen.visibleFrame
            let origin: CGPoint
            switch placement {
            case .center:
                origin = CGPoint(
                    x: sf.midX - panelSize.width / 2 + CGFloat(sessions.count) * 20,
                    y: sf.midY - panelSize.height / 2 - CGFloat(sessions.count) * 20
                )
            case .bottomRight:
                // 历史记录贴图：落在屏幕右下角，多张时向左上错开避免完全重叠。
                let margin: CGFloat = 24
                let offset = CGFloat(sessions.count) * 24
                origin = CGPoint(
                    x: sf.maxX - margin - panelSize.width - offset,
                    y: sf.minY + margin + offset
                )
            }
            panel.setFrameOrigin(origin)
        }

        sessions.append(Session(panel: panel, interaction: interaction))
        panel.orderFront(nil)
        installMonitor()
    }

    /// Closes all pinned panels.
    func unpinAll() {
        sessions.forEach { $0.panel.orderOut(nil) }
        sessions.removeAll()
        teardownMonitorIfNeeded()
    }

    /// 鼠标穿透开启后，贴图本身收不到点击；菜单栏提供统一恢复入口。
    func restoreInteractions() {
        for session in sessions {
            session.interaction.clickThrough = false
            session.panel.ignoresMouseEvents = false
        }
    }

    // MARK: - 原生事件监听（移动 / 四角等比缩放 / 滚轮缩放）

    /// 前三版把事件处理挂在窗口里的视图上，但贴图是"不抢焦点"的悬浮窗，
    /// 视图层始终收不到后台状态下的鼠标按下。改为进程内本地事件监听：
    /// 只要事件发给本程序，这里一定能看到，不依赖任何视图的命中测试。
    private var monitor: Any?
    private var activeSession: Session?
    private var dragMode: PinDragMode?

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event)
        }
    }

    private func teardownMonitorIfNeeded() {
        guard sessions.isEmpty else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        activeSession = nil
        dragMode = nil
    }

    /// 返回 nil 表示事件已被贴图消费（吞掉），不再继续传递。
    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        // 本地监听阶段事件的 window 字段常为空，不能按 window 匹配；
        // 改按"事件位置落在哪张贴图上"判断；拖拽中沿用 activeSession。
        let mouse = screenLocation(of: event)
        guard let session = activeSession ?? session(at: mouse),
              !session.interaction.clickThrough else { return event }
        let frame = session.panel.frame

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-pin-drag") {
            print("[monitor] type=\(event.type.rawValue) mouse=\(mouse) frame=\(frame)")
        }
        #endif

        switch event.type {
        case .leftMouseDown:
            // 四角手柄：命中则开始等比缩放
            if let corner = hitResizeCorner(mouse, in: frame) {
                beginResize(session: session, corner: corner, mouse: mouse)
                return nil
            }
            // 顶部工具条保护带：按钮在那里，事件放行给按钮
            let fromTop = frame.maxY - mouse.y
            if session.interaction.isHovered && fromTop <= 46 { return event }
            beginMove(session: session, mouse: mouse)
            return nil

        case .leftMouseDragged:
            guard let mode = dragMode else { return event }
            switch mode {
            case .move(let state):
                session.panel.setFrameOrigin(NSPoint(
                    x: state.startOrigin.x + (mouse.x - state.startMouse.x),
                    y: state.startOrigin.y + (mouse.y - state.startMouse.y)
                ))
            case .resize(let state):
                applyResize(session: session, state: state, mouse: mouse)
            }
            return nil

        case .leftMouseUp:
            let wasDragging = dragMode != nil
            dragMode = nil
            activeSession = nil
            session.interaction.isInteracting = false
            return wasDragging ? nil : event

        case .scrollWheel:
            let delta = event.deltaY
            if delta != 0 {
                let newScale = (session.interaction.scaleFactor + delta * 0.05)
                    .clamped(to: 0.25...4.0)
                applyScale(session: session, newScale: newScale, anchor: nil)
            }
            return nil

        default:
            return event
        }
    }

    /// 事件时刻的鼠标屏幕位置（左下原点，与 window.frame 同坐标系）。
    /// 优先从底层 CGEvent 取原始全局位置（合成事件也准确，不依赖 window 归属）。
    private func screenLocation(of event: NSEvent) -> CGPoint {
        if let cgEvent = event.cgEvent {
            let location = cgEvent.location
            let mainScreenHeight = CGDisplayBounds(CGMainDisplayID()).height
            return CGPoint(x: location.x, y: mainScreenHeight - location.y)
        }
        if let window = event.window {
            let point = event.locationInWindow
            return CGPoint(
                x: window.frame.origin.x + point.x,
                y: window.frame.origin.y + point.y
            )
        }
        return NSEvent.mouseLocation
    }

    /// 鼠标位置所在的贴图（后贴的在上层，倒序找）。
    private func session(at point: CGPoint) -> Session? {
        sessions.last { NSPointInRect(point, $0.panel.frame) }
    }

    /// 点击位置是否落在某个缩放手柄上（手柄中心在角内 10pt，命中半径 22pt）。
    private func hitResizeCorner(_ mouse: CGPoint, in frame: NSRect) -> PinCorner? {
        let centers: [(PinCorner, CGPoint)] = [
            (.topLeft, CGPoint(x: frame.minX + 10, y: frame.maxY - 10)),
            (.topRight, CGPoint(x: frame.maxX - 10, y: frame.maxY - 10)),
            (.bottomLeft, CGPoint(x: frame.minX + 10, y: frame.minY + 10)),
            (.bottomRight, CGPoint(x: frame.maxX - 10, y: frame.minY + 10))
        ]
        return centers.first { _, center in
            hypot(mouse.x - center.x, mouse.y - center.y) <= 22
        }?.0
    }

    private func beginMove(session: Session, mouse: CGPoint) {
        activeSession = session
        dragMode = .move(PinMoveState(
            startMouse: mouse,
            startOrigin: session.panel.frame.origin
        ))
        session.interaction.isInteracting = true
    }

    private func beginResize(session: Session, corner: PinCorner, mouse: CGPoint) {
        let frame = session.panel.frame
        // 锚点=被拖角的对角（屏幕坐标，同为左下原点）
        let anchor: CGPoint
        switch corner {
        case .topLeft: anchor = CGPoint(x: frame.maxX, y: frame.minY)
        case .topRight: anchor = CGPoint(x: frame.minX, y: frame.minY)
        case .bottomLeft: anchor = CGPoint(x: frame.maxX, y: frame.maxY)
        case .bottomRight: anchor = CGPoint(x: frame.minX, y: frame.maxY)
        }
        activeSession = session
        dragMode = .resize(PinResizeState(
            corner: corner,
            baseScale: session.interaction.scaleFactor,
            anchor: anchor,
            startDistance: hypot(mouse.x - anchor.x, mouse.y - anchor.y)
        ))
        session.interaction.isInteracting = true
    }

    /// 等比缩放：抓住的角跟手、对面的角钉在 anchor，宽高同比例。
    private func applyResize(session: Session, state: PinResizeState, mouse: CGPoint) {
        guard state.startDistance > 8 else { return }
        let distance = hypot(mouse.x - state.anchor.x, mouse.y - state.anchor.y)
        let newScale = (state.baseScale * distance / state.startDistance)
            .clamped(to: 0.25...4.0)
        applyScale(session: session, newScale: newScale, anchor: (state.corner, state.anchor))
    }

    /// 统一的缩放落地：改 interaction.scaleFactor（SwiftUI 界面自动跟随）+ 调整窗口。
    /// anchor 为空时固定左上角（菜单百分比、滚轮用）；拖角时固定对角。
    private func applyScale(session: Session, newScale: CGFloat, anchor: (PinCorner, CGPoint)?) {
        session.interaction.scaleFactor = newScale
        let size = session.panel.frame.size
        let newSize = CGSize(
            width: max(session.interaction.baseSize.width * newScale, 60),
            height: max(session.interaction.baseSize.height * newScale, 40)
        )
        guard newSize != size else { return }
        var frame = session.panel.frame
        frame.size = newSize
        if let (corner, anchorPoint) = anchor {
            switch corner {
            case .topLeft:
                frame.origin.x = anchorPoint.x - newSize.width
                frame.origin.y = anchorPoint.y
            case .topRight:
                frame.origin.x = anchorPoint.x
                frame.origin.y = anchorPoint.y
            case .bottomLeft:
                frame.origin.x = anchorPoint.x - newSize.width
                frame.origin.y = anchorPoint.y - newSize.height
            case .bottomRight:
                frame.origin.x = anchorPoint.x
                frame.origin.y = anchorPoint.y - newSize.height
            }
        } else {
            // 固定左上角
            frame.origin.y += size.height - newSize.height
        }
        session.panel.setFrame(frame, display: true, animate: false)
    }

    #if DEBUG
    /// 无人值守自测（--audit-pin-drag）：生成测试图→贴图→合成鼠标事件→
    /// 自动判定"移动"和"四角等比缩放"是否真的生效，结果写 /tmp/rune-pin-drag-result.txt。
    func runPinDragSelfTest() {
        let size = NSSize(width: 300, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let url = URL(fileURLWithPath: "/tmp/rune-pin-selftest.png")
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }

        pin(url: url, on: NSScreen.main, placement: .center, auditShowsControls: true)
        guard let session = sessions.last else {
            try? "FAIL ❌ 贴图未创建".write(toFile: "/tmp/rune-pin-drag-result.txt", atomically: true, encoding: .utf8)
            return
        }
        let panel = session.panel
        let interaction = session.interaction
        let pid = ProcessInfo.processInfo.processIdentifier

        Task { @MainActor in
            func post(_ type: CGEventType, _ point: CGPoint) {
                let screenH = CGDisplayBounds(CGMainDisplayID()).height
                let cg = CGPoint(x: point.x, y: screenH - point.y)
                CGEvent(
                    mouseEventSource: nil,
                    mouseType: type,
                    mouseCursorPosition: cg,
                    mouseButton: .left
                )?.postToPid(pid)
            }

            try? await Task.sleep(for: .milliseconds(900))

            // —— 移动：中心按下，拖 +140/+90 ——
            let f0 = panel.frame
            let center = CGPoint(x: f0.midX, y: f0.midY)
            post(.leftMouseDown, center)
            try? await Task.sleep(for: .milliseconds(250))
            post(.leftMouseDragged, CGPoint(x: center.x + 140, y: center.y + 90))
            try? await Task.sleep(for: .milliseconds(250))
            post(.leftMouseDragged, CGPoint(x: center.x + 140, y: center.y + 90))
            try? await Task.sleep(for: .milliseconds(250))
            post(.leftMouseUp, CGPoint(x: center.x + 140, y: center.y + 90))
            try? await Task.sleep(for: .milliseconds(300))
            let f1 = panel.frame
            let movePassed = abs(f1.origin.x - f0.origin.x) > 100 && abs(f1.origin.y - f0.origin.y) > 60

            // —— 缩放：右下角手柄，向对角(左上)反方向拉远 1.6 倍 ——
            let s0 = interaction.scaleFactor
            let handle = CGPoint(x: f1.maxX - 10, y: f1.minY + 10)
            let anchor = CGPoint(x: f1.minX, y: f1.maxY)
            let d0 = hypot(handle.x - anchor.x, handle.y - anchor.y)
            let outward = CGPoint(x: anchor.x + d0 * 1.6, y: anchor.y - d0 * 1.6)
            post(.leftMouseDown, handle)
            try? await Task.sleep(for: .milliseconds(250))
            post(.leftMouseDragged, outward)
            try? await Task.sleep(for: .milliseconds(250))
            post(.leftMouseDragged, outward)
            try? await Task.sleep(for: .milliseconds(250))
            post(.leftMouseUp, outward)
            try? await Task.sleep(for: .milliseconds(300))
            let s1 = interaction.scaleFactor
            let scalePassed = s1 > s0 * 1.2

            let report = """
            移动: \(movePassed ? "PASS ✅" : "FAIL ❌")  origin \(f0.origin) -> \(f1.origin)
            缩放: \(scalePassed ? "PASS ✅" : "FAIL ❌")  scale \(s0) -> \(s1)
            """
            try? report.write(toFile: "/tmp/rune-pin-drag-result.txt", atomically: true, encoding: .utf8)
            print("[贴图自测]\n" + report)

            try? await Task.sleep(for: .milliseconds(400))
            NSApp.terminate(nil)
        }
    }
    #endif
}

@MainActor
@Observable
private final class PinnedScreenshotInteraction {
    var opacity: Double = 1.0
    var clickThrough = false
    // 缩放比例与基准尺寸：控制器的事件监听直接改，SwiftUI 界面自动跟随
    var scaleFactor: CGFloat = 1.0
    var baseSize: CGSize = .zero
    // 悬停/拖拽中：由视图回写，控制器判断"顶部是否要让位给工具条按钮"
    var isHovered = false
    var isInteracting = false
}

/// 贴图拖拽的两种模式。
private enum PinDragMode {
    case move(PinMoveState)
    case resize(PinResizeState)
}

// MARK: - 贴图落点

/// 新贴图在屏幕上的初始位置。
enum PinnedPlacement {
    case center
    case bottomRight
}

// MARK: - PinnedScreenshotView

/// SwiftUI content view for a single pinned screenshot panel.
/// 只负责绘制：移动/缩放/滚轮统一由 PinnedScreenshotController 的本地事件监听处理。
private struct PinnedScreenshotView: View {
    let image: NSImage
    let sourceURL: URL?
    @Bindable var interaction: PinnedScreenshotInteraction
    let alwaysShowsControls: Bool
    let onClose: () -> Void

    @State private var hostingWindow: NSWindow?
    // 复制成功的轻反馈：按钮短暂变成"已复制"
    @State private var showsCopiedFeedback = false

    private var showsControls: Bool {
        (interaction.isHovered || alwaysShowsControls || interaction.isInteracting)
            && !interaction.clickThrough
    }

    var body: some View {
        let w = interaction.baseSize.width * interaction.scaleFactor
        let h = interaction.baseSize.height * interaction.scaleFactor

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
                .help("拖动移动，拖四角按比例缩放，滚轮缩放；悬停可显示贴图工具条")

            if showsControls {
                pinToolbar
                    .padding(.top, 8)
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
            }

            // 四角手柄常驻显示（不依赖悬停），提示"角上能拖"。
            ForEach(PinCorner.allCases, id: \.self) { corner in
                PinCornerHandleDot()
                    .frame(width: 34, height: 34)
                    .position(corner.point(in: CGSize(width: w, height: h)))
                    .allowsHitTesting(false)
                    .help("拖动按比例缩放贴图")
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
        // 悬停状态回写给控制器：它要知道"顶部是否有工具条需要让位"
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                interaction.isHovered = hovering
            }
        }
        .contextMenu {
            Button("复制图片") {
                copyImage()
            }
            if let sourceURL {
                Button("编辑图片") {
                    EditorWindowController.shared.open(url: sourceURL)
                }
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
                }
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
        .onChange(of: interaction.scaleFactor) { _, _ in
            // 菜单百分比缩放后，同步窗口尺寸（固定左上角）
            guard let window = hostingWindow else { return }
            let newSize = CGSize(
                width: max(interaction.baseSize.width * interaction.scaleFactor, 60),
                height: max(interaction.baseSize.height * interaction.scaleFactor, 40)
            )
            guard window.frame.size != newSize else { return }
            var frame = window.frame
            frame.origin.y += frame.size.height - newSize.height
            frame.size = newSize
            window.setFrame(frame, display: true, animate: false)
        }
    }

    /// 图太窄时完整工具条会比图宽，两端悬空既点不到又会让悬停判断失效，
    /// 因此窄图自动换成紧凑版：只留复制、编辑、关闭和"更多"。
    private var usesCompactToolbar: Bool {
        interaction.baseSize.width * interaction.scaleFactor < 300
    }

    private var pinToolbar: some View {
        HStack(spacing: 7) {
            copyButton

            if let sourceURL {
                Button {
                    EditorWindowController.shared.open(url: sourceURL)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 24, height: 24)
                }
                .help("打开编辑器")
            }

            if usesCompactToolbar {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .help("关闭贴图")

                RuneMenu(
                    surface: .chrome,
                    entries: {
                        var list: [RuneMenuEntry] = [0.5, 0.75, 1.0, 1.5, 2.0].map { value in
                            .item(
                                RuneMenuItem(
                                    "大小 \(Int(value * 100))%",
                                    isSelected: abs(interaction.scaleFactor - value) < 0.01
                                ) {
                                    interaction.scaleFactor = value
                                }
                            )
                        }
                        list.append(.divider)
                        list.append(contentsOf: [0.3, 0.6, 1.0].map { value in
                            .item(
                                RuneMenuItem(
                                    "透明度 \(Int(value * 100))%",
                                    isSelected: abs(interaction.opacity - value) < 0.01
                                ) {
                                    interaction.opacity = value
                                }
                            )
                        })
                        list.append(.divider)
                        list.append(
                            .item(RuneMenuItem("开启鼠标穿透", systemImage: "arrow.pointer.forward") {
                                interaction.clickThrough = true
                            })
                        )
                        return list
                    }
                ) {
                    Image(systemName: "ellipsis")
                        .frame(width: 24, height: 24)
                }
                .help("更多操作")
            } else {
                Divider()
                    .frame(height: 18)

                Image(systemName: "circle.lefthalf.filled")
                    .font(RuneFont.swiftUI(size: 10))
                    .foregroundStyle(.secondary)

                Slider(value: $interaction.opacity, in: 0.2...1.0, step: 0.1)
                    .frame(width: 62)
                    .controlSize(.mini)
                    .help("透明度 \(Int(interaction.opacity * 100))%")

                RuneMenu(
                    surface: .chrome,
                    menuWidth: 120,
                    entries: {
                        [0.5, 0.75, 1.0, 1.5, 2.0].map { value in
                            .item(
                                RuneMenuItem(
                                    "\(Int(value * 100))%",
                                    isSelected: abs(interaction.scaleFactor - value) < 0.01
                                ) {
                                    interaction.scaleFactor = value
                                }
                            )
                        }
                    }
                ) {
                    Text("\(Int(interaction.scaleFactor * 100))%")
                        .font(RuneFont.swiftUI(size: 10, weight: .medium))
                        .frame(minWidth: 34)
                }
                .help("贴图大小")

                Button {
                    interaction.clickThrough = true
                } label: {
                    Image(systemName: "cursorarrow.rays")
                        .frame(width: 24, height: 24)
                }
                .help("开启鼠标穿透；从 Rune 菜单恢复")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .help("关闭贴图")
            }
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

    /// 最常用操作：带文字的主按钮，点完短暂显示"已复制"确认。
    private var copyButton: some View {
        Button(action: copyImage) {
            HStack(spacing: 4) {
                Image(systemName: showsCopiedFeedback ? "checkmark" : "doc.on.doc")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                Text(showsCopiedFeedback ? "已复制" : "复制")
                    .font(RuneFont.swiftUI(size: 10, weight: .semibold))
            }
            .foregroundStyle(RuneTheme.accent)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(RuneTheme.accent.opacity(0.15), in: Capsule())
            .animation(.easeInOut(duration: 0.15), value: showsCopiedFeedback)
        }
        .buttonStyle(.plain)
        .help("复制图片到剪贴板")
    }

    // MARK: 拖角缩放：对角为锚点

    private func copyImage() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        // 轻反馈：按钮短暂变成"已复制"，让用户确认真的复制上了
        showsCopiedFeedback = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            showsCopiedFeedback = false
        }
    }
}

// MARK: - 四角手柄（纯视觉）

/// 四角白色圆点：只负责提示"角上能拖"。移动/缩放/滚轮事件全部由
/// PinnedScreenshotController 的本地事件监听统一处理，不依赖视图命中测试。
private struct PinCornerHandleDot: NSViewRepresentable {
    func makeNSView(context: Context) -> _PinCornerHandleDotNSView {
        _PinCornerHandleDotNSView()
    }

    func updateNSView(_ view: _PinCornerHandleDotNSView, context: Context) {}
}

final class _PinCornerHandleDotNSView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let dot = CAShapeLayer()
        dot.fillColor = NSColor.white.cgColor
        dot.strokeColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dot.lineWidth = 1
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowRadius = 2
        layer?.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let dot = layer?.sublayers?.first as? CAShapeLayer else { return }
        dot.frame = bounds
        let dotRect = NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12)
        dot.path = CGPath(ellipseIn: dotRect, transform: nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - 贴图四角

/// 一次拖角缩放的起始快照：锚点（对角）与起始距离固定，缩放比=距离比，绝不抖动。
private struct PinResizeState {
    let corner: PinCorner
    let baseScale: CGFloat
    let anchor: CGPoint
    let startDistance: CGFloat
}

/// 一次拖动移动的起始快照：起始鼠标位置 + 起始窗口原点（均为屏幕坐标）。
private struct PinMoveState {
    let startMouse: CGPoint
    let startOrigin: CGPoint
}

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
