import AppKit
import CaptureKit
import CaptureKitSCK
@preconcurrency import ScreenCaptureKit

struct RegionSelection {
    let pointsRect: CGRect  // In global display points (top-left origin, matching SCK coordinates)
    let scaleFactor: CGFloat
    /// 实际框选所在显示器的编号（NSScreen 非 Sendable 不能直接传出；
    /// 消费方用编号换回屏幕，冻结屏+工具栏跟随框选所在屏）
    let displayID: CGDirectDisplayID
    /// 区域+窗口合并模式：单击命中窗口时为该窗口 ID（nil = 普通拖拽选区）
    let windowID: CGWindowID?
    /// 截图来源应用。窗口点击为精确来源；区域框选取中心点最上层窗口。
    let source: CaptureSource?
}

/// 区域+窗口合并模式的候选窗口（Sendable：SCWindow 不能直接传出）。
struct WindowCandidate: Sendable {
    let id: CGWindowID
    let source: CaptureSource?
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
    private var frozenFramesByDisplay: [CGDirectDisplayID: CGImage] = [:]
    private var frontmostSource: CaptureSource?

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
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           let name = app.localizedName {
            frontmostSource = CaptureSource(
                bundleIdentifier: app.bundleIdentifier,
                applicationName: name,
                windowTitle: nil,
                processID: app.processIdentifier
            )
        }

        // ① 先弹窗口（无定格帧/窗口清单）：按快捷键瞬间出现、立即可拖拽。
        //    修"第一次拖拽没反应"——此前要等 1-2.5s 的定格帧抓取完才建窗口，
        //    用户第一次按下时界面还不存在，事件落在桌面上。
        var views: [(screen: NSScreen, view: SelectionView)] = []
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

            let overlayView = SelectionView(
                screen: screen,
                frozenFrame: nil,
                windows: [],
                fallbackSource: frontmostSource,
                cursor: crosshair
            ) { [weak self] rect, source in
                self?.finishSelection(rect: rect, screen: screen, source: source)
            } onSelectWindow: { [weak self] candidate in
                self?.finishWindowSelection(candidate: candidate, screen: screen)
            } onCancel: { [weak self] in
                self?.cancelSelection()
            }

            window.contentView = overlayView
            // 只前置不出键：窗口立即接收鼠标，但激活/成为 key 会抢走前台的
            // 焦点、把用户正开着的菜单/弹窗收掉——那必须等静帧抓完再干。
            window.orderFrontRegardless()
            overlayWindows.append(window)
            views.append((screen, overlayView))
        }

        crosshair.push()
        crosshair.set()

        // ② 静帧 + 窗口清单先抓（此刻屏幕状态未被打扰），抓完回填各屏视图
        await fetchOverlayData(for: views)

        // ③ 静帧到手才接管焦点（此刻真菜单即使收起，浮层上显示的仍是
        // 收起前的定格画面）；激活后 Esc 取消也才可用
        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.first?.makeKeyAndOrderFront(nil)
    }

    /// 抓定格帧（每屏并行）+ 窗口清单，抓完回填 SelectionView。
    private func fetchOverlayData(for views: [(screen: NSScreen, view: SelectionView)]) async {
        // 从共享保温缓存取屏幕清单（启动时常驻预热已焐热）：窗口清单和悬停
        // 高亮即时就绪，不再等 0.5–1.5s 现查——快速单击也能正确命中窗口，
        // 而不是因清单为空退化成全屏。定格帧仍在下面现抓，保持"此刻"。
        let shareableContent = (try? await freezeEngine.shareableContent())?.content
        let myBundleID = Bundle.main.bundleIdentifier ?? ""

        // SCShareableContent.windows 没有承诺按前后层级排列。真正的窗口层级来自
        // CGWindowListCopyWindowInfo：返回顺序就是屏幕上从前到后。
        let cgWindowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] ?? []
        var zOrderByWindowID: [CGWindowID: Int] = [:]
        var layerByWindowID: [CGWindowID: Int] = [:]
        var alphaByWindowID: [CGWindowID: CGFloat] = [:]
        for (index, info) in cgWindowInfo.enumerated() {
            guard let number = info[kCGWindowNumber] as? NSNumber else { continue }
            let id = CGWindowID(number.uint32Value)
            zOrderByWindowID[id] = index
            layerByWindowID[id] = (info[kCGWindowLayer] as? NSNumber)?.intValue ?? 0
            alphaByWindowID[id] = (info[kCGWindowAlpha] as? NSNumber).map {
                CGFloat(truncating: $0)
            } ?? 1
        }

        let ignoredSystemBundleIDs: Set<String> = [
            "com.apple.controlcenter",
            "com.apple.dock",
            "com.apple.loginwindow",
            "com.apple.notificationcenterui",
            "com.apple.systemuiserver",
            "com.apple.WindowManager",
        ]

        // 窗口候选（SCWindow.frame 为 CG 坐标：主屏左上原点、y 向下）
        var candidates: [WindowCandidate] = []
        if let windows = shareableContent?.windows {
            for window in windows {
                let bundleID = window.owningApplication?.bundleIdentifier ?? ""
                let layer = layerByWindowID[window.windowID] ?? window.windowLayer
                guard (0...20).contains(layer),
                      (alphaByWindowID[window.windowID] ?? 1) > 0.05,
                      window.frame.width >= 60, window.frame.height >= 40,
                      bundleID != myBundleID,
                      !bundleID.isEmpty,
                      !ignoredSystemBundleIDs.contains(bundleID) else { continue }
                let app = window.owningApplication
                let source = app.map {
                    CaptureSource(
                        bundleIdentifier: $0.bundleIdentifier,
                        applicationName: $0.applicationName,
                        windowTitle: window.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                        processID: $0.processID
                    )
                }
                candidates.append(WindowCandidate(
                    id: window.windowID,
                    source: source,
                    cgFrame: window.frame
                ))
            }
        }
        candidates.sort {
            let lhs = zOrderByWindowID[$0.id] ?? Int.max
            let rhs = zOrderByWindowID[$1.id] ?? Int.max
            return lhs < rhs
        }

        // 定格帧：逐屏抓（界面已先弹出，此处不阻塞交互；排除自身避免拍进 overlay）。
        // 注：不用 TaskGroup 并行——SCContentFilter 非 Sendable 不能跨任务传。
        var frozenFrames: [CGDirectDisplayID: CGImage] = [:]
        if let displays = shareableContent?.displays {
            let excludedApps = shareableContent?.applications.filter {
                $0.bundleIdentifier == myBundleID
            } ?? []
            for display in displays {
                let filter = SCContentFilter(
                    display: display,
                    excludingApplications: excludedApps,
                    exceptingWindows: []
                )
                let config = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                if let img = try? await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config
                ) {
                    frozenFrames[display.displayID] = img
                }
            }
        }
        frozenFramesByDisplay = frozenFrames

        // 回填：定格帧 + 本屏局部坐标窗口清单
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        for (screen, view) in views {
            let displayID = (screen.deviceDescription[screenNumberKey] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? 0
            view.updateFrozenFrame(frozenFrames[displayID])
            // cgFrame → AppKit 全局（y=主屏高−cgMaxY）→ 减本屏原点
            let localWindows = candidates.compactMap { candidate -> WindowCandidate? in
                var c = candidate
                let appKitGlobal = CGRect(
                    x: candidate.cgFrame.minX,
                    y: primaryHeight - candidate.cgFrame.maxY,
                    width: candidate.cgFrame.width,
                    height: candidate.cgFrame.height
                )
                c.localRect = appKitGlobal.offsetBy(
                    dx: -screen.frame.origin.x, dy: -screen.frame.origin.y
                )
                let localScreenBounds = CGRect(origin: .zero, size: screen.frame.size)
                guard !c.localRect.intersection(localScreenBounds).isNull else { return nil }
                return c
            }
            view.updateWindowCandidates(localWindows)
        }
    }


    // MARK: - 快门签名（选区完成）

    /// 光圈收缩 + 一次触感白色脉冲：ADA "Delight" 的签名动效。
    /// reduce-motion 跳过；脉冲层挂 OverlayWindow 的 contentView layer。
    private func fireShutterPulse(in rect: CGRect, on screen: NSScreen) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else { return }

        guard let window = overlayWindows.first,
              let host = window.contentView else { return }

        let inset = rect.insetBy(dx: -3, dy: -3)
        let pulse = CAShapeLayer()
        pulse.fillColor = NSColor.clear.cgColor
        pulse.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        pulse.lineWidth = 1.6
        pulse.frame = inset
        pulse.path = CGPath(
            roundedRect: pulse.bounds,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
        if host.layer == nil { host.wantsLayer = true }
        host.layer!.addSublayer(pulse)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.045
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.88
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.64
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        pulse.add(group, forKey: "shutterPulse")
    }

    private func finishSelection(
        rect: CGRect,
        screen: NSScreen,
        source: CaptureSource?
    ) {
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
            windowID: nil,
            source: source ?? frontmostSource
        )

        completeSelection(
            selection,
            shutterRect: rect,
            on: screen
        )
    }

    /// 单击命中窗口：整窗捕获（走 SCK desktopIndependentWindow，不带阴影）。
    private func finishWindowSelection(candidate: WindowCandidate, screen: NSScreen) {
        NSCursor.pop()

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let rect = candidate.localRect
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
            windowID: candidate.id,
            source: candidate.source
        )

        completeSelection(selection, shutterRect: nil, on: screen)
    }

    /// 先让选区蒙层真正退出窗口服务器，再恢复截图流程。
    ///
    /// 旧逻辑为了保留快门脉冲，延迟 80ms 才 `orderOut`，却立刻恢复
    /// continuation；定格帧尚未回填时，后续实拍会偶发把灰色遮罩一起抓进去。
    /// 这里把“WindowServer 已确认退场”变成恢复捕获的硬前置条件。
    private func completeSelection(
        _ selection: RegionSelection,
        shutterRect: CGRect?,
        on screen: NSScreen
    ) {
        guard let pendingContinuation = continuation else { return }
        continuation = nil

        if let shutterRect {
            fireShutterPulse(in: shutterRect, on: screen)
        }

        Task { @MainActor [weak self] in
            if shutterRect != nil,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                try? await Task.sleep(for: .milliseconds(80))
            }

            let retiredWindowIDs = self?.closeOverlays() ?? []
            CATransaction.flush()

            // 不再猜固定延时：直接确认所有选区窗已经从 WindowServer 的屏幕
            // 窗口列表消失，再额外让出一帧给合成器，后续实拍获得硬保证。
            await Self.waitForWindowServerToRetire(retiredWindowIDs)
            pendingContinuation.resume(returning: selection)
        }
    }

    private func cancelSelection() {
        NSCursor.pop()
        closeOverlays()
        continuation?.resume(returning: nil)
        continuation = nil
    }

    @discardableResult
    private func closeOverlays() -> Set<CGWindowID> {
        let windowIDs = Set(overlayWindows.map { CGWindowID($0.windowNumber) })
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        return windowIDs
    }

    private static func waitForWindowServerToRetire(_ windowIDs: Set<CGWindowID>) async {
        guard !windowIDs.isEmpty else { return }
        for _ in 0..<12 {
            let visibleWindows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
            ) as? [[CFString: Any]] ?? []
            let visibleIDs = Set(visibleWindows.compactMap { info in
                (info[kCGWindowNumber] as? NSNumber).map {
                    CGWindowID($0.uint32Value)
                }
            })
            if windowIDs.isDisjoint(with: visibleIDs) {
                try? await Task.sleep(for: .milliseconds(16))
                return
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
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
    private struct ElementHover {
        let localRect: CGRect
        let source: CaptureSource
    }

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var mouseLocation: NSPoint?
    private var trackingArea: NSTrackingArea?
    private let screen: NSScreen
    private let fallbackSource: CaptureSource?
    /// 定格帧（选区背景）。界面先弹出、此帧后台抓完回填。
    private var frozenFrame: CGImage?
    private let crosshairCursor: NSCursor
    /// 区域+窗口+全屏合并：本屏候选窗口（局部坐标）。数组顺序=前到后，命中取第一个。
    /// 界面先弹出、清单后台抓完回填。
    private var windows: [WindowCandidate]
    /// 当前悬停命中的窗口（画高亮；单击=截整窗）
    private var hoveredWindow: WindowCandidate?
    private var hoveredElement: ElementHover?
    /// mouseDown 后悬停态会清空，但单击确认仍需记住按下时命中的界面区域。
    private var pressedElement: ElementHover?
    private var elementDetectionTask: Task<Void, Never>?
    private let onSelect: (CGRect, CaptureSource?) -> Void
    private let onSelectWindow: (WindowCandidate) -> Void
    private let onCancel: () -> Void

    /// M1 §3.4 状态机：驱动选区流程（比例轮换、方向键微调、确认、取消）。
    /// 用 CaptureKit 的 CaptureStateMachine（纯值类型，可独立测试）。
    private var machine = CaptureStateMachine()

    init(
        screen: NSScreen,
        frozenFrame: CGImage?,
        windows: [WindowCandidate],
        fallbackSource: CaptureSource?,
        cursor: NSCursor,
        onSelect: @escaping (CGRect, CaptureSource?) -> Void,
        onSelectWindow: @escaping (WindowCandidate) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.screen = screen
        self.frozenFrame = frozenFrame
        self.windows = windows
        self.fallbackSource = fallbackSource
        self.crosshairCursor = cursor
        self.onSelect = onSelect
        self.onSelectWindow = onSelectWindow
        self.onCancel = onCancel
        super.init(frame: screen.frame)
    }

    /// 后台抓完定格帧后回填（界面已可交互，只是背景从"实时"换成"定格"）。
    func updateFrozenFrame(_ image: CGImage?) {
        frozenFrame = image
        needsDisplay = true
    }

    /// 后台抓完窗口清单后回填（悬停识别随后生效）。
    func updateWindowCandidates(_ candidates: [WindowCandidate]) {
        windows = candidates
        if dragStart == nil, let m = mouseLocation {
            hoveredWindow = hitWindow(at: m)
            scheduleElementDetection(at: m)
        }
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// 热键触发时 Rune 还是后台应用，而覆盖层刻意只 orderFront 不激活（保住
    /// 用户开着的菜单进冻结帧）。未激活应用的窗口第一下点击会被系统拿去激活、
    /// 不派发给视图——表现为"必须点两下"。这里让第一下点击照常激活的同时
    /// 直接送达视图，选区立即开始（与 ConfirmCanvasView 同一配方）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
            // 区域+窗口+全屏合并：悬停命中窗口=窗口高亮；空白处=全屏预告
            if let element = hoveredElement {
                drawHighlight(
                    rect: element.localRect,
                    isWindow: true,
                    sourceName: "\(element.source.applicationName) · 界面区域"
                )
            } else if let hovered = hoveredWindow ?? mouseLocation.flatMap({ hitWindow(at: $0) }) {
                hoveredWindow = hovered
                drawHighlight(
                    rect: hovered.localRect,
                    isWindow: true,
                    sourceName: hovered.source?.applicationName
                )
            } else if mouseLocation != nil {
                drawHighlight(
                    rect: bounds.insetBy(dx: 3, dy: 3),
                    isWindow: false,
                    sourceName: nil
                )
            }
            if let mouse = mouseLocation {
                drawGuideLines(at: mouse)
            }
            drawHint()
        }
    }

    /// 悬停高亮：窗口=挖空遮罩+光谱细边；全屏=整屏光谱细边（不用挖空）。
    /// 标签统一画在矩形上方（放不下挪下方）。
    private func drawHighlight(
        rect: CGRect,
        isWindow: Bool,
        sourceName: String?
    ) {
        if isWindow {
            // 遮罩挖空窗口区域（窗口内保持清晰）
            let maskPath = NSBezierPath(rect: bounds)
            maskPath.append(NSBezierPath(rect: rect))
            maskPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.25).setFill()
            maskPath.fill()
        }

        drawSpectralBorder(rect, lineWidth: isWindow ? 2 : 1.5)

        // 标签：尺寸（物理像素）+ 单击提示
        let w = Int(rect.width * screen.backingScaleFactor)
        let h = Int(rect.height * screen.backingScaleFactor)
        let prefix = isWindow ? (sourceName ?? "窗口") : "屏幕"
        let action = isWindow ? "单击截取窗口" : "单击截取全屏"
        let label = "\(prefix) · \(w) × \(h) · \(action)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: RuneFont.appKit(size: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let labelSize = label.size(withAttributes: attrs)
        var labelRect = CGRect(
            x: rect.midX - labelSize.width / 2 - 8,
            y: rect.maxY + 10,
            width: labelSize.width + 16,
            height: labelSize.height + 6
        )
        // 标签超出屏幕顶部时挪到矩形内底部
        if labelRect.maxY > bounds.maxY {
            labelRect.origin.y = rect.minY + 10
        }
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        label.draw(at: NSPoint(x: labelRect.minX + 8, y: labelRect.minY + 3), withAttributes: attrs)
    }

    /// 底部操作提示（拖拽开始前显示）：三种用法 + 取消方式。
    private func drawHint() {
        let hint = "单击窗口＝截整窗　·　点桌面空白＝截全屏　·　拖拽＝自定义区域　·　Esc/右键＝取消" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: RuneFont.appKit(size: 12, weight: .medium),
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

        // 选区边框沿用 Rune 的冷暖分段光谱语义。
        drawSpectralBorder(selectionRect, lineWidth: 1.5)

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
            .font: RuneFont.appKit(size: 11, weight: .medium),
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

    /// 不使用粗重圆角或整圈霓虹：左下是冷色，右上是暖色，像薄玻璃的折射边。
    private func drawSpectralBorder(_ rect: CGRect, lineWidth: CGFloat) {
        let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)

        NSColor.white.withAlphaComponent(0.20).setStroke()
        let foundation = NSBezierPath(rect: inset)
        foundation.lineWidth = 0.5
        foundation.stroke()

        let cool = NSBezierPath()
        cool.move(to: NSPoint(x: inset.maxX, y: inset.minY))
        cool.line(to: NSPoint(x: inset.minX, y: inset.minY))
        cool.line(to: NSPoint(x: inset.minX, y: inset.maxY))
        cool.lineWidth = lineWidth
        RuneTheme.nsCyan.setStroke()
        cool.stroke()

        let warm = NSBezierPath()
        warm.move(to: NSPoint(x: inset.minX, y: inset.maxY))
        warm.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        warm.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        warm.lineWidth = lineWidth
        RuneTheme.nsMagenta.setStroke()
        warm.stroke()

        let highlight = NSBezierPath()
        highlight.move(to: NSPoint(x: max(inset.midX, inset.maxX - 72), y: inset.maxY))
        highlight.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
        highlight.lineWidth = lineWidth
        RuneTheme.nsAmber.setStroke()
        highlight.stroke()
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
        scheduleElementDetection(at: mouseLocation!)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        crosshairCursor.set()
        let loc = convert(event.locationInWindow, from: nil)
        pressedElement = hoveredElement
        dragStart = loc
        dragCurrent = loc
        mouseLocation = nil
        hoveredElement = nil
        elementDetectionTask?.cancel()
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
            pressedElement = nil
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
            let center = CGPoint(x: rect.midX, y: rect.midY)
            onSelect(rect, hitWindow(at: center)?.source ?? fallbackSource)
        } else if let element = pressedElement,
                  element.localRect.insetBy(dx: -2, dy: -2).contains(end) {
            machine.reduce(.confirm)
            onSelect(element.localRect, element.source)
        } else if let hit = hitWindow(at: end) {
            // 区域+窗口+全屏合并：原地点击命中窗口 → 截整窗
            machine.reduce(.confirm)
            onSelectWindow(hit)
        } else {
            // 原地点击未命中窗口 → 截整屏（点桌面=全屏，与其他家一致）
            machine.reduce(.confirm)
            onSelect(bounds, fallbackSource)
        }
    }

    /// 右键 = 取消（与 Esc 等效）。
    override func rightMouseDown(with event: NSEvent) {
        machine.reduce(.cancel)
        onCancel()
    }

    /// 命中检测：候选按前到后排序，取第一个包含点的窗口。
    private func hitWindow(at point: NSPoint) -> WindowCandidate? {
        windows.first { $0.localRect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    /// Snipaste 同类的界面元素识别：停稳约 70ms 后查询前台应用在该点暴露的
    /// 边界。查询放到后台，避免 Electron 等应用拖慢十字光标。
    private func scheduleElementDetection(at localPoint: CGPoint) {
        elementDetectionTask?.cancel()
        hoveredElement = nil
        guard dragStart == nil,
              AppPreferences.detectUIElements,
              UIElementDetector.isTrusted,
              let window = hitWindow(at: localPoint),
              let processID = window.source?.processID,
              let source = window.source else { return }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let cgPoint = CGPoint(
            x: screen.frame.minX + localPoint.x,
            y: primaryHeight - (screen.frame.minY + localPoint.y)
        )
        let cgWindowFrame = window.cgFrame

        elementDetectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            let candidate = await UIElementDetector.detect(
                at: cgPoint,
                processID: processID,
                inside: cgWindowFrame
            )
            guard !Task.isCancelled, let self, let candidate,
                  self.dragStart == nil,
                  let current = self.mouseLocation,
                  hypot(current.x - localPoint.x, current.y - localPoint.y) < 3 else { return }

            let appKitGlobal = CGRect(
                x: candidate.cgFrame.minX,
                y: primaryHeight - candidate.cgFrame.maxY,
                width: candidate.cgFrame.width,
                height: candidate.cgFrame.height
            )
            let localRect = appKitGlobal.offsetBy(
                dx: -self.screen.frame.minX,
                dy: -self.screen.frame.minY
            ).intersection(self.bounds)
            guard localRect.width >= 60, localRect.height >= 40 else { return }
            self.hoveredElement = ElementHover(localRect: localRect, source: source)
            self.needsDisplay = true
        }
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
        let center = CGPoint(x: rect.midX, y: rect.midY)
        onSelect(rect, hitWindow(at: center)?.source ?? fallbackSource)
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
