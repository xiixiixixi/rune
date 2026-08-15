import AppKit
import CaptureKit
import CaptureKitSCK
import ScreenCaptureKit

struct RegionSelection {
    let pointsRect: CGRect  // In global display points (top-left origin, matching SCK coordinates)
    let scaleFactor: CGFloat
    /// 实际框选所在显示器的编号（NSScreen 非 Sendable 不能直接传出；
    /// 消费方用编号换回屏幕，冻结屏+工具栏跟随框选所在屏）
    let displayID: CGDirectDisplayID
    /// 区域+窗口合并模式：单击命中窗口时为该窗口 ID（nil = 普通拖拽选区）
    let windowID: CGWindowID?
}

/// 区域+窗口合并模式的候选窗口（Sendable：SCWindow 不能直接传出）。
struct WindowCandidate: Sendable {
    let id: CGWindowID
    /// SCWindow.frame 的原始值——**CG 坐标系：主屏左上为原点、y 向下**
    /// （探针实测：探针窗 AppKit y=500 → SCK 报 608 = 1440-500-332）。
    /// 尺寸=窗口实际 frame 不含阴影；SCShareableContent 顺序=前到后。
    let cgFrame: CGRect
    /// 所在屏的局部坐标（AppKit 左下原点；由 overlay 按屏换算填充）
    var localRect: CGRect = .zero
}

@MainActor
final class RegionSelectionOverlay {

    private var overlayWindows: [NSWindow] = []
    private var continuation: CheckedContinuation<RegionSelection?, Never>?

    /// M1 §3.3：选区前先抓冻结帧。冻结帧作为 overlay 背景，使选区时屏幕内容不变化。
    private let freezeEngine = SCKStillCaptureBackend()

    func selectRegion() async -> RegionSelection? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            Task { await self.showOverlays() }
        }
    }

    private func showOverlays() async {
        let crosshair = CrosshairCursor.shared.makeCursor()

        // 先抓每个显示器的冻结帧（排除自身，避免把 overlay 拍进去）
        var frozenFrames: [CGDirectDisplayID: CGImage] = [:]
        let shareableContent = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))
        // 区域+窗口合并：收集普通层窗口（点击即截整窗）；rect 已换算到各屏局部坐标
        var windowCandidates: [WindowCandidate] = []
        if let windows = shareableContent?.windows {
            let myBundleID = Bundle.main.bundleIdentifier ?? ""
            for window in windows {
                guard window.windowLayer == 0,
                      window.frame.width >= 60, window.frame.height >= 40,
                      window.owningApplication?.bundleIdentifier != myBundleID else { continue }
                windowCandidates.append(
                    WindowCandidate(id: window.windowID, cgFrame: window.frame)
                )
            }
        }
        if let displays = shareableContent?.displays {
            let myBundleID = Bundle.main.bundleIdentifier ?? ""
            let excludedApps = shareableContent?.applications.filter { $0.bundleIdentifier == myBundleID } ?? []
            for display in displays {
                let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                    frozenFrames[display.displayID] = img
                }
            }
        }

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]

            // 取该屏的冻结帧（取不到时为 nil，回退到纯遮罩模式）
            let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
            let displayID = (screen.deviceDescription[screenNumberKey] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) } ?? 0
            let frozenFrame = frozenFrames[displayID]
            // 本屏的候选窗口。SCWindow.frame 是 CG 坐标（主屏左上原点、y 向下），
            // 要先翻成 AppKit 全局（左下原点）再减本屏原点：
            // appKitY = 主屏高 − cgMaxY（与 finishSelection 的正向换算互为逆运算）
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let localWindows = windowCandidates.compactMap { candidate -> WindowCandidate? in
                var c = candidate
                let appKitGlobal = CGRect(
                    x: candidate.cgFrame.minX,
                    y: primaryHeight - candidate.cgFrame.maxY,
                    width: candidate.cgFrame.width,
                    height: candidate.cgFrame.height
                )
                c.localRect = appKitGlobal.offsetBy(dx: -screen.frame.origin.x, dy: -screen.frame.origin.y)
                guard !c.localRect.intersection(screen.frame).isNull else { return nil }
                return c
            }
            let overlayView = SelectionView(
                screen: screen,
                frozenFrame: frozenFrame,
                windows: localWindows,
                cursor: crosshair
            ) { [weak self] rect in
                self?.finishSelection(rect: rect, screen: screen)
            } onSelectWindow: { [weak self] windowID, rect in
                self?.finishWindowSelection(windowID: windowID, rect: rect, screen: screen)
            } onCancel: { [weak self] in
                self?.cancelSelection()
            }

            window.contentView = overlayView
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        crosshair.push()
        crosshair.set()
    }

    private func finishSelection(rect: CGRect, screen: NSScreen) {
        NSCursor.pop()

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height

        let globalX = screen.frame.origin.x + rect.origin.x
        let globalY = primaryHeight - (screen.frame.origin.y + rect.origin.y + rect.height)

        let pointsRect = CGRect(
            x: globalX,
            y: globalY,
            width: rect.width,
            height: rect.height
        )

        // deviceDescription 里存的是 NSNumber，直接 as? CGDirectDisplayID 会失败
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        let displayID = (screen.deviceDescription[screenNumberKey] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
        let selection = RegionSelection(
            pointsRect: pointsRect,
            scaleFactor: screen.backingScaleFactor,
            displayID: displayID,
            windowID: nil
        )

        closeOverlays()
        continuation?.resume(returning: selection)
        continuation = nil
    }

    /// 单击命中窗口：整窗捕获（走 SCK desktopIndependentWindow，不带阴影）。
    private func finishWindowSelection(windowID: CGWindowID, rect: CGRect, screen: NSScreen) {
        NSCursor.pop()

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let globalX = screen.frame.origin.x + rect.origin.x
        let globalY = primaryHeight - (screen.frame.origin.y + rect.origin.y + rect.height)
        let pointsRect = CGRect(x: globalX, y: globalY, width: rect.width, height: rect.height)

        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        let displayID = (screen.deviceDescription[screenNumberKey] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) } ?? 0
        let selection = RegionSelection(
            pointsRect: pointsRect,
            scaleFactor: screen.backingScaleFactor,
            displayID: displayID,
            windowID: windowID
        )

        closeOverlays()
        continuation?.resume(returning: selection)
        continuation = nil
    }

    private func cancelSelection() {
        NSCursor.pop()
        closeOverlays()
        continuation?.resume(returning: nil)
        continuation = nil
    }

    private func closeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}

// MARK: - Custom Crosshair "+" Cursor (matches macOS screenshot tool)

@MainActor
final class CrosshairCursor {
    static let shared = CrosshairCursor()

    func makeCursor() -> NSCursor {
        let size: CGFloat = 40
        let center = size / 2
        let lineLength: CGFloat = 16
        let gap: CGFloat = 4

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        NSGraphicsContext.current?.shouldAntialias = true

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()

        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round

        // Horizontal line (left segment)
        path.move(to: NSPoint(x: center - lineLength, y: center))
        path.line(to: NSPoint(x: center - gap, y: center))
        // Horizontal line (right segment)
        path.move(to: NSPoint(x: center + gap, y: center))
        path.line(to: NSPoint(x: center + lineLength, y: center))
        // Vertical line (bottom segment)
        path.move(to: NSPoint(x: center, y: center - lineLength))
        path.line(to: NSPoint(x: center, y: center - gap))
        // Vertical line (top segment)
        path.move(to: NSPoint(x: center, y: center + gap))
        path.line(to: NSPoint(x: center, y: center + lineLength))

        path.stroke()

        // Draw center "+" cross
        let plusPath = NSBezierPath()
        plusPath.lineWidth = 1.5
        plusPath.lineCapStyle = .round
        let plusSize: CGFloat = 2.5
        plusPath.move(to: NSPoint(x: center - plusSize, y: center))
        plusPath.line(to: NSPoint(x: center + plusSize, y: center))
        plusPath.move(to: NSPoint(x: center, y: center - plusSize))
        plusPath.line(to: NSPoint(x: center, y: center + plusSize))
        plusPath.stroke()

        image.unlockFocus()

        return NSCursor(image: image, hotSpot: NSPoint(x: center, y: center))
    }
}

// MARK: - Overlay Window (prevents AppKit cursor resets)

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        // Swallow cursor updates — we manage the cursor ourselves in SelectionView
    }
}

// MARK: - Selection View

private final class SelectionView: NSView {
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var mouseLocation: NSPoint?
    private var trackingArea: NSTrackingArea?
    private let screen: NSScreen
    private let frozenFrame: CGImage?  // M1 §3.3 冻结帧（选区背景）
    private let crosshairCursor: NSCursor
    /// 区域+窗口合并：本屏候选窗口（局部坐标）。数组顺序=前到后，命中取第一个。
    private let windows: [WindowCandidate]
    /// 当前悬停命中的窗口（画高亮；单击=截整窗）
    private var hoveredWindow: WindowCandidate?
    private let onSelect: (CGRect) -> Void
    private let onSelectWindow: (CGWindowID, CGRect) -> Void
    private let onCancel: () -> Void

    /// M1 §3.4 状态机：驱动选区流程（比例轮换、方向键微调、确认、取消）。
    /// 用 CaptureKit 的 CaptureStateMachine（纯值类型，可独立测试）。
    private var machine = CaptureStateMachine()

    init(
        screen: NSScreen,
        frozenFrame: CGImage?,
        windows: [WindowCandidate],
        cursor: NSCursor,
        onSelect: @escaping (CGRect) -> Void,
        onSelectWindow: @escaping (CGWindowID, CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.frozenFrame = frozenFrame
        self.windows = windows
        self.crosshairCursor = cursor
        self.onSelect = onSelect
        self.onSelectWindow = onSelectWindow
        self.onCancel = onCancel
        super.init(frame: screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: crosshairCursor)
        crosshairCursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        crosshairCursor.set()
    }

    // MARK: - Drawing

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // M1 §3.3：先画冻结帧（若有），使选区时屏幕内容冻结不变。
        if let frozenFrame, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(frozenFrame, in: bounds)
            ctx.restoreGState()
        }

        // 在冻结帧之上画半透明遮罩（无冻结帧时遮罩更浓，作为回退）
        let maskAlpha: CGFloat = (frozenFrame != nil) ? 0.2 : 0.3
        NSColor.black.withAlphaComponent(maskAlpha).setFill()
        bounds.fill()

        if let start = dragStart, let current = dragCurrent {
            drawSelection(start: start, current: current)
        } else {
            // 区域+窗口合并：悬停窗口 = 红框高亮 + 挖空遮罩 + 尺寸标签
            if let hovered = hoveredWindow ?? mouseLocation.flatMap({ hitWindow(at: $0) }) {
                hoveredWindow = hovered
                drawWindowHighlight(hovered)
            }
            if let mouse = mouseLocation {
                drawGuideLines(at: mouse)
            }
            drawHint()
        }
    }

    /// 悬停窗口高亮：挖空遮罩 + 红色圆角描边 + 顶部"窗口 · 尺寸"标签。
    private func drawWindowHighlight(_ window: WindowCandidate) {
        let rect = window.localRect

        // 遮罩挖空窗口区域（窗口内保持清晰）
        let maskPath = NSBezierPath(rect: bounds)
        maskPath.append(NSBezierPath(rect: rect))
        maskPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.25).setFill()
        maskPath.fill()

        // 红色圆角描边（轻截点缀红）
        let accent = NSColor(red: 1.0, green: 0.231, blue: 0.189, alpha: 1)
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
        border.lineWidth = 2.5
        accent.setStroke()
        border.stroke()

        // 标签：窗口尺寸（物理像素）+ 提示
        let w = Int(rect.width * screen.backingScaleFactor)
        let h = Int(rect.height * screen.backingScaleFactor)
        let label = "窗口 · \(w) × \(h) · 单击截取" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        var labelRect = CGRect(
            x: rect.midX - labelSize.width / 2 - 8,
            y: rect.maxY + 10,
            width: labelSize.width + 16,
            height: labelSize.height + 6
        )
        // 标签超出屏幕顶部时挪到窗口内底部
        if labelRect.maxY > bounds.maxY {
            labelRect.origin.y = rect.minY - labelRect.height - 10
        }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: labelRect.minX + 8, y: labelRect.minY + 3), withAttributes: attrs)
    }

    /// 底部操作提示（拖拽开始前显示）：教会"单击=整窗 / 拖拽=自定义"。
    private func drawHint() {
        let hint = "单击窗口＝截整窗　·　拖拽＝自定义区域　·　Esc＝取消" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = hint.size(withAttributes: attrs)
        let rect = CGRect(
            x: bounds.midX - size.width / 2 - 12,
            y: bounds.minY + 64,
            width: size.width + 24,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        hint.draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 4), withAttributes: attrs)
    }

    private func drawGuideLines(at point: NSPoint) {
        let lineColor = NSColor.white.withAlphaComponent(0.4)
        lineColor.setStroke()

        let path = NSBezierPath()
        path.lineWidth = 0.5

        // Vertical guide line
        path.move(to: NSPoint(x: point.x, y: bounds.minY))
        path.line(to: NSPoint(x: point.x, y: bounds.maxY))

        // Horizontal guide line
        path.move(to: NSPoint(x: bounds.minX, y: point.y))
        path.line(to: NSPoint(x: bounds.maxX, y: point.y))

        path.stroke()
    }

    private func drawSelection(start: NSPoint, current: NSPoint) {
        let selectionRect = rectFromPoints(start, current)
        guard selectionRect.width > 2, selectionRect.height > 2 else { return }

        // M1 §3.3：遮罩覆盖选区外区域（even-odd 规则挖空选区），让选区内显示冻结帧。
        let maskPath = NSBezierPath(rect: bounds)
        maskPath.append(NSBezierPath(rect: selectionRect))
        maskPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.3).setFill()
        maskPath.fill()

        // 选区边框
        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: selectionRect)
        borderPath.lineWidth = 1.5
        borderPath.stroke()

        // 尺寸提示标签（含当前比例模式，让用户看到 Tab 切换效果）
        let w = Int(selectionRect.width * screen.backingScaleFactor)
        let h = Int(selectionRect.height * screen.backingScaleFactor)
        let ratioText: String = {
            switch machine.aspectRatioMode {
            case .free: return ""
            case .ratio1_1: return "  (1:1)"
            case .ratio3_4: return "  (3:4)"
            case .ratio16_9: return "  (16:9)"
            }
        }()
        let label = "\(w) × \(h)\(ratioText)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        let labelRect = CGRect(
            x: selectionRect.midX - labelSize.width / 2 - 6,
            y: selectionRect.minY - labelSize.height - 8,
            width: labelSize.width + 12,
            height: labelSize.height + 4
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attrs)
    }

    // MARK: - Mouse Events

    override func mouseEntered(with event: NSEvent) {
        crosshairCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        crosshairCursor.set()
        mouseLocation = convert(event.locationInWindow, from: nil)
        // 区域+窗口合并：悬停识别窗口（未进入拖拽时）
        hoveredWindow = (dragStart == nil) ? hitWindow(at: mouseLocation!) : nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        crosshairCursor.set()
        let loc = convert(event.locationInWindow, from: nil)
        dragStart = loc
        dragCurrent = loc
        mouseLocation = nil
        // M1 §3.4：开始拖拽，通知状态机进入 selecting
        machine.reduce(.selectionBegan)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        crosshairCursor.set()
        var loc = convert(event.locationInWindow, from: nil)
        // M1 §3.3：若有比例约束，按 aspectRatioMode 调整 dragCurrent
        loc = constrainToAspectRatio(loc)
        dragCurrent = loc
        // 拖出幅度超过阈值 → 明确是自定义拉取，窗口高亮退场
        if let start = dragStart, hypot(loc.x - start.x, loc.y - start.y) > 4 {
            hoveredWindow = nil
        }
        machine.reduce(.selectionChanged)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let rect = rectFromPoints(start, end)

        if rect.width > 3, rect.height > 3 {
            machine.reduce(.confirm)
            onSelect(rect)
        } else if let hit = hitWindow(at: end) {
            // 区域+窗口合并：原地点击命中窗口 → 截整窗
            machine.reduce(.confirm)
            onSelectWindow(hit.id, hit.localRect)
        } else {
            machine.reduce(.cancel)
            onCancel()
        }
    }

    /// 命中检测：候选按前到后排序，取第一个包含点的窗口。
    private func hitWindow(at point: NSPoint) -> WindowCandidate? {
        windows.first { $0.localRect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// M1 §3.4 键盘交互：Esc 取消、Tab 轮换比例、方向键微调选区、Enter 确认。
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:  // Esc → 取消
            machine.reduce(.cancel)
            onCancel()
        case 48:  // Tab → 轮换比例模式（free → 1:1 → 3:4 → 16:9）
            machine.reduce(.modeCycle)
            needsDisplay = true
        case 123, 124, 125, 126:  // 左右上下 → 微调选区（仅在已拖出选区时）
            nudgeSelection(by: event.keyCode)
        case 36:  // Enter → 确认选区
            confirmSelection()
        default:
            break
        }
    }

    /// 方向键微调 dragCurrent（每次 1 点）。
    private func nudgeSelection(by keyCode: UInt16) {
        guard dragStart != nil, var cur = dragCurrent else { return }
        let step: CGFloat = 1.0
        switch keyCode {
        case 123: cur.x -= step  // 左
        case 124: cur.x += step  // 右
        case 125: cur.y -= step  // 下
        case 126: cur.y += step  // 上
        default: break
        }
        cur = constrainToAspectRatio(cur)
        dragCurrent = cur
        machine.reduce(.adjustBegan)
        needsDisplay = true
    }

    /// Enter 确认：等同于 mouseUp 确认选区。
    private func confirmSelection() {
        guard let start = dragStart, let end = dragCurrent else { return }
        let rect = rectFromPoints(start, end)
        guard rect.width > 3, rect.height > 3 else { return }
        machine.reduce(.confirm)
        onSelect(rect)
    }

    /// 按 aspectRatioMode 约束目标点（保持 dragStart 固定，调整 dragCurrent 满足比例）。
    private func constrainToAspectRatio(_ loc: NSPoint) -> NSPoint {
        guard let start = dragStart, let ratio = machine.aspectRatioMode.ratio else { return loc }
        let dx = loc.x - start.x
        let dy = loc.y - start.y
        // 以 X 为基准算 Y（取绝对值再还原方向）
        let absX = abs(dx)
        let absY = absX * CGFloat(ratio.height) / CGFloat(ratio.width)
        return NSPoint(x: loc.x, y: start.y + (dy >= 0 ? absY : -absY))
    }

    private func rectFromPoints(_ a: NSPoint, _ b: NSPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }
}
