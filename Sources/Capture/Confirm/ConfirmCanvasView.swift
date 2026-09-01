import AppKit
import QuartzCore

extension Notification.Name {
    static let confirmCanvasStateDidChange = Notification.Name("Rune.ConfirmCanvasStateDidChange")
    static let confirmCaptureContentDidChange = Notification.Name("Rune.ConfirmCaptureContentDidChange")
}

/// 确认模式画布：显示截图 + 就地标注（拖画/选中/移动/删除）。
///
/// 复用 AnnotationItem 模型（0-1 归一化、Y-down）与 AnnotationDrawing 烘焙渲染。
/// 键盘（没有编辑文字时）：Esc=取消、Enter=复制并保存、⌘Z=撤销、Delete=删除选中。
final class ConfirmCanvasView: NSView {
    private let image: CGImage
    private let backgroundImage: CGImage?
    private let capturedRegion: CGRect?
    private let screen: NSScreen
    private weak var controller: CaptureConfirmController?
    private var pulseLayers: [CAShapeLayer] = []

    // MARK: - 标注状态（工具栏读写；确认时由控制器读走烘焙）

    var annotations: [AnnotationItem] = []
    private var undoStack: [[AnnotationItem]] = []

    var selectedTool: AnnotationTool = .select
    var selectedSwatch: AnnotationSwatch = .mustard   // 与工具栏默认一致（曾不同步导致默认仍是红）
    var strokeWidth: CGFloat = 4

    /// 当前选中的标注（选择工具点中后可拖动/Delete；工具栏切工具时置 nil）
    var selectedID: AnnotationItem.ID?

    // 绘制中
    private var draft: AnnotationItem?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    // 选中拖动
    private var movingID: AnnotationItem.ID?
    private var moveOffset: CGPoint = .zero

    // 选字模式（钉钉/飞书式）：识别出的文字块可点选/划选复制
    var ocrMode = false
    private(set) var ocrBlocks: [(text: String, frame: CGRect)] = []   // frame=视图坐标
    private var ocrDragStart: CGPoint?
    private var ocrDragRect: CGRect?

    // 截图内容理解：确认台出现后在后台识别，不阻塞保存、复制和取消。
    private var contentAnalysisTask: Task<Void, Never>?
    private(set) var contentAnalysisState: CaptureContentAnalysisState = .analyzing

    init(
        image: CGImage,
        backgroundImage: CGImage?,
        capturedRegion: CGRect?,
        screen: NSScreen,
        controller: CaptureConfirmController
    ) {
        self.image = image
        self.backgroundImage = backgroundImage
        self.capturedRegion = capturedRegion
        self.screen = screen
        self.controller = controller
        super.init(frame: screen.frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// 工具栏是独立面板。即使它短暂拿走了 key window，用户回到画布的
    /// 第一次按下也必须直接开始标注，不能只用来激活画布、让首次拖拽失效。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        if window != nil {
            startFreezePulse()
            beginContentAnalysis()
        } else {
            cancelContentAnalysis()
        }
    }

    override func layout() {
        super.layout()
        layoutPulseLayers()
    }

    // MARK: - 工具栏入口（撤销 / 删除选中）

    func undo() {
        guard !undoStack.isEmpty else { return }
        annotations = undoStack.removeLast()
        selectedID = nil
        needsDisplay = true
        postCanvasStateChange()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// 选中态下改颜色/粗细（CleanShot 式：点工具栏色点/粗细直接改选中标注）
    func updateSelectedAnnotation(swatch: AnnotationSwatch? = nil, strokeWidth: CGFloat? = nil) {
        guard let id = selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        if let swatch { annotations[idx].swatch = swatch }
        if let strokeWidth { annotations[idx].strokeWidth = strokeWidth }
        needsDisplay = true
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
        needsDisplay = true
    }

    private func pushUndo() {
        undoStack.append(annotations)
        postCanvasStateChange()
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 先画蒙层退出后重新抓取的干净整屏帧。没有帧时用深色回退，
        // 不再叠加会让用户误以为成片发灰的全屏暗幕。
        if let backgroundImage {
            ctx.saveGState()
            ctx.interpolationQuality = .medium
            ctx.draw(backgroundImage, in: bounds)
            ctx.restoreGState()
        } else {
            NSColor(calibratedRed: 0.025, green: 0.028, blue: 0.038, alpha: 1).setFill()
            bounds.fill()
        }

        // 2. 截中的画面回到原来的空间位置，而不是重新居中展示。
        ctx.saveGState()
        ctx.interpolationQuality = .high
        let drawRect = imageDrawRect
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()

        // 3. 只保留细边界标识选区；选区外维持原始亮度。
        drawFrozenEdge(around: drawRect)

        // 3.5 选字模式：文字块高亮（必须在"无标注提前 return"之前，
        // 否则刚截完图（0 标注）时蓝块永远画不出来）
        if ocrMode {
            // 拖动中用划选矩形；松手后用保留的选中矩形（选中态持续显示）
            let selRect = ocrDragRect ?? ocrSelectedRect
            for block in ocrBlocks {
                let selected = selRect.map { !$0.intersection(block.frame).isNull } ?? false
                NSColor.systemBlue.withAlphaComponent(selected ? 0.45 : 0.14).setFill()
                block.frame.insetBy(dx: -2, dy: -1).fill()
            }
            if let selRect {
                NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
                let path = NSBezierPath(rect: selRect)
                path.lineWidth = 1.2
                path.setLineDash([5, 3], count: 2, phase: 0)
                path.stroke()
            }
        }

        // 4. 画标注（归一化坐标映射到 drawRect；Y-down → CG 用 flipped 渲染）
        // 马赛克草稿特殊处理：AnnotationDrawing 的 blur 需要画布快照（此处没有），
        // 拖拽阶段由本视图直接画棋盘格预览（选中即见"这是打码"），保存烘焙才是真马赛克
        var items = annotations
        if let draft {
            if draft.tool == .blur, draft.rect.width > 0.003, draft.rect.height > 0.003 {
                drawCheckerboardPreview(in: viewRect(for: draft.rect), ctx: ctx)
            } else {
                items.append(draft)
            }
        }
        guard !items.isEmpty else { return }

        // 屏幕窗口的 CGContext 不能稳定生成快照，AnnotationDrawing 的打码预览会因此为空。
        // 确认台直接从原图裁出并处理打码区域；保存时仍走统一的烘焙渲染。
        drawRedactionPreviews(items)

        let vectorItems = items.filter { !$0.tool.isRedactionTool }
        if !vectorItems.isEmpty {
            ctx.saveGState()
            // AnnotationDrawing.draw(flipped:true) 要求上下文为 Y-down：整体翻转一次
            ctx.translateBy(x: 0, y: drawRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let flippedRect = CGRect(x: drawRect.minX, y: 0, width: drawRect.width, height: drawRect.height)
            AnnotationDrawing.draw(
                vectorItems,
                in: ctx,
                imageRect: flippedRect,
                fullCanvasRect: flippedRect,
                sourceImage: image,
                flipped: true
            )
            ctx.restoreGState()
        }

        // 5. 选中高亮：红色圆角虚线框 + 四角白色手柄方块（视觉上"可操作"）
        if let id = selectedID,
           let item = annotations.first(where: { $0.id == id }) {
            let r = viewRect(for: item.bounds).insetBy(dx: -4, dy: -4)
            let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(path)
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.85).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            // 四角手柄：白底红边小方块
            let hs: CGFloat = 7
            for corner in [r.origin,
                           CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY),
                           CGPoint(x: r.maxX, y: r.maxY)] {
                let rect = CGRect(x: corner.x - hs/2, y: corner.y - hs/2, width: hs, height: hs)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setStrokeColor(NSColor.systemRed.cgColor)
                ctx.setLineWidth(1.5)
                ctx.fill(rect)
                ctx.stroke(rect)
            }
        }
    }

    private func drawRedactionPreviews(_ items: [AnnotationItem]) {
        let scale = imageDrawRect.width / max(CGFloat(image.width), 1)
        for item in items where item.tool.isRedactionTool {
            guard let preview = RedactionImageProcessor.previewImageFromCGImage(
                source: image,
                tool: item.tool,
                density: item.redactionDensity,
                normalizedBounds: item.bounds,
                viewScale: scale
            ) else { continue }
            preview.draw(
                in: viewRect(for: item.bounds),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: item.tool == .pixelate ? NSImageInterpolation.none : .medium]
            )
        }
    }

    /// 按当前工具切换光标：画图=十字，选择=箭头。
    override func resetCursorRects() {
        let cursor: NSCursor = ocrMode
            ? .iBeam
            : (selectedTool == .select ? .arrow : .crosshair)
        addCursorRect(bounds, cursor: cursor)
    }

    /// 工具切换后刷新光标（工具栏改 selectedTool 后调）。
    func refreshCursor() {
        window?.invalidateCursorRects(for: self)
    }

    /// 归一化 rect → 视图 rect。
    /// 注意用 bounds 而非 frame：副屏的 frame 带全局原点（如 2560,540），
    /// 当局部坐标用会把图整个画到可视区外。
    var imageDrawRect: CGRect {
        if let capturedRegion {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            let appKitGlobal = CGRect(
                x: capturedRegion.minX,
                y: primaryHeight - capturedRegion.maxY,
                width: capturedRegion.width,
                height: capturedRegion.height
            )
            return appKitGlobal.offsetBy(
                dx: -screen.frame.minX,
                dy: -screen.frame.minY
            ).intersection(bounds)
        }

        let scale = screen.backingScaleFactor
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if abs(pointSize.width - bounds.width) < 2,
           abs(pointSize.height - bounds.height) < 2 {
            return bounds
        }
        return CGRect(
            x: bounds.midX - pointSize.width / 2,
            y: bounds.midY - pointSize.height / 2,
            width: pointSize.width,
            height: pointSize.height
        )
    }

    private func drawFrozenEdge(around rect: CGRect) {
        guard rect.width > 4, rect.height > 4 else { return }
        // 确认态沿用选区的冷暖分段细边，不再使用厚重白色圆角框。
        let edge = rect.insetBy(dx: 1, dy: 1)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let foundation = NSBezierPath(rect: edge)
        foundation.lineWidth = 0.5
        foundation.stroke()

        let cool = NSBezierPath()
        cool.move(to: CGPoint(x: edge.maxX, y: edge.minY))
        cool.line(to: CGPoint(x: edge.minX, y: edge.minY))
        cool.line(to: CGPoint(x: edge.minX, y: edge.maxY))
        cool.lineWidth = 1.4
        RuneTheme.nsCyan.setStroke()
        cool.stroke()

        let warm = NSBezierPath()
        warm.move(to: CGPoint(x: edge.minX, y: edge.maxY))
        warm.line(to: CGPoint(x: edge.maxX, y: edge.maxY))
        warm.line(to: CGPoint(x: edge.maxX, y: edge.minY))
        warm.lineWidth = 1.4
        RuneTheme.nsMagenta.setStroke()
        warm.stroke()

        // 四角短刻度是快门的定位框，也是 Rune 的裁切角线签名——印在这里。
        let tick = min(18, max(9, min(rect.width, rect.height) * 0.08))
        let inset: CGFloat = 7
        let x0 = rect.minX - inset
        let x1 = rect.maxX + inset
        let y0 = rect.minY - inset
        let y1 = rect.maxY + inset
        let ticks = NSBezierPath()
        ticks.lineWidth = 2
        ticks.lineCapStyle = .round
        ticks.move(to: CGPoint(x: x0, y: y0 + tick)); ticks.line(to: CGPoint(x: x0, y: y0)); ticks.line(to: CGPoint(x: x0 + tick, y: y0))
        ticks.move(to: CGPoint(x: x1 - tick, y: y0)); ticks.line(to: CGPoint(x: x1, y: y0)); ticks.line(to: CGPoint(x: x1, y: y0 + tick))
        ticks.move(to: CGPoint(x: x0, y: y1 - tick)); ticks.line(to: CGPoint(x: x0, y: y1)); ticks.line(to: CGPoint(x: x0 + tick, y: y1))
        ticks.move(to: CGPoint(x: x1 - tick, y: y1)); ticks.line(to: CGPoint(x: x1, y: y1)); ticks.line(to: CGPoint(x: x1, y: y1 - tick))
        RuneTheme.nsAmber.setStroke()
        ticks.stroke()
    }

    private func startFreezePulse() {
        pulseLayers.forEach { $0.removeFromSuperlayer() }
        pulseLayers.removeAll()
        guard let hostLayer = layer else { return }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else {
            layoutPulseLayers()
            return
        }

        // 只有一次轻微的呼吸脉冲：确认「这里已锁定」，然后归于安静。
        let pulse = CAShapeLayer()
        pulse.fillColor = NSColor.clear.cgColor
        pulse.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
        pulse.lineWidth = 1.4
        pulse.opacity = 0
        hostLayer.addSublayer(pulse)
        pulseLayers.append(pulse)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.03
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.6
        group.beginTime = CACurrentMediaTime() + 0.02
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        pulse.add(group, forKey: "freezePulse")
        layoutPulseLayers()
    }

    private func layoutPulseLayers() {
        let pulseFrame = imageDrawRect.insetBy(dx: -7, dy: -7)
        guard pulseFrame.width > 4, pulseFrame.height > 4 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for pulse in pulseLayers {
            pulse.frame = pulseFrame
            pulse.path = CGPath(
                roundedRect: pulse.bounds.insetBy(dx: 1, dy: 1),
                cornerWidth: 12,
                cornerHeight: 12,
                transform: nil
            )
        }
        CATransaction.commit()
    }

    private func postCanvasStateChange() {
        NotificationCenter.default.post(name: .confirmCanvasStateDidChange, object: self)
    }

    private func postContentAnalysisChange() {
        NotificationCenter.default.post(name: .confirmCaptureContentDidChange, object: self)
    }

    private func viewRect(for normalized: CGRect) -> CGRect {
        let r = imageDrawRect
        return CGRect(
            x: r.minX + normalized.minX * r.width,
            y: r.minY + (1 - normalized.maxY) * r.height,   // Y-down → 视图 Y-up
            width: normalized.width * r.width,
            height: normalized.height * r.height
        )
    }

    /// 视图点 → 归一化点（Y-down）。
    /// 注意：AppKit 视图坐标原点在左下角（Y 向上），模型要 Y-down（顶部=0），
    /// 所以 Y 必须用 maxY 反着算，否则标注上下镜像（往下拉却往上画）。
    private func normalizedPoint(_ p: CGPoint) -> CGPoint {
        let r = imageDrawRect
        return CGPoint(
            x: min(max((p.x - r.minX) / r.width, 0), 1),
            y: min(max((r.maxY - p.y) / r.height, 0), 1)
        )
    }

    /// 棋盘格预览：马赛克拖拽时所见即所得（黑白格 = 打码的直觉符号）。
    private func drawCheckerboardPreview(in rect: CGRect, ctx: CGContext) {
        let cell: CGFloat = 9
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        var row = 0
        var y = rect.minY - cell
        while y < rect.maxY {
            var col = 0
            var x = rect.minX - cell
            while x < rect.maxX {
                if (row + col) % 2 == 0 {
                    ctx.fill(
                        CGRect(x: x, y: y, width: cell, height: cell).intersection(rect)
                    )
                }
                x += cell
                col += 1
            }
            y += cell
            row += 1
        }
        ctx.restoreGState()
        // 边框提示范围
        NSColor.black.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.stroke()
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // 点到文字框以外时，先结束上一段文字：空内容丢弃，有内容保留。
        // 这样保持文字工具连续放置时，也不会残留一个失去焦点的输入框。
        finishTextEditing()
        // 暗场只是“时间冻结”的背景，不是可编辑画布；标注只发生在截中的亮区。
        guard imageDrawRect.contains(loc) else { return }

        // 选字模式：点中文字块立即复制（不依赖 mouseUp——实测其派发不稳定）；
        // 同时记录划选起点，拖动/松开由队列级兜底钩子处理
        if ocrMode {
            ocrSelectedRect = nil   // 新一轮选择：清掉上次的选中态
            if let block = ocrBlocks.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(loc) }) {
                copyBlocks([block])
                ToastWindow.shared.show(
                    title: "文字识别",
                    message: "已复制：\(block.text.prefix(24))",
                    systemIcon: "doc.on.doc"
                )
            }
            ocrDragStart = loc
            ocrDragRect = nil
            needsDisplay = true
            return
        }

        let n = normalizedPoint(loc)

        if selectedTool == .select {
            // 点选：命中检测（从后往前=最上层优先）
            if let hit = annotations.last(where: ({ item in
                let b = item.bounds.insetBy(dx: -0.01, dy: -0.01)
                return b.contains(n)
            })) {
                selectedID = hit.id
                movingID = hit.id
                moveOffset = CGPoint(x: n.x - hit.bounds.midX, y: n.y - hit.bounds.midY)
            } else {
                selectedID = nil
            }
            needsDisplay = true
            return
        }

        // 编号圆点：点击放置、固定尺寸（不做拖大拖小），颜色跟色点
        if selectedTool == .numberedCircle {
            pushUndo()
            let r = imageDrawRect
            // 宽、高分别归一化（÷各自维度）→ 映射回像素是 22×22 正圆。
            // 只除高度的话，宽高比≠1 的图里会被横向拉成椭圆（用户实测抓到的 bug）。
            let wNorm = 22.0 / max(r.width, 1)
            let hNorm = 22.0 / max(r.height, 1)
            let next = annotations.filter { $0.tool == .numberedCircle }.count + 1
            let item = AnnotationItem(
                tool: .numberedCircle,
                rect: CGRect(x: n.x - wNorm / 2, y: n.y - hNorm / 2, width: wNorm, height: hNorm),
                points: [],
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                text: "\(next)"
            )
            annotations.append(item)
            selectedID = item.id
            needsDisplay = true
            return
        }

        // 文字：点击放置 + 就地输入（回车换行；切换工具时智能收尾）
        if selectedTool == .text {
            beginTextPlacement(at: loc)
            return
        }

        // 图形类：开始拖画
        dragStart = n
        dragCurrent = n
        beginDraft(at: n)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let n = normalizedPoint(loc)

        // 移动选中标注
        if selectedTool == .select, let id = movingID,
           let idx = annotations.firstIndex(where: { $0.id == id }) {
            let b = annotations[idx].bounds
            let newCenter = CGPoint(x: n.x - moveOffset.x, y: n.y - moveOffset.y)
            let dx = newCenter.x - b.midX
            let dy = newCenter.y - b.midY
            shiftAnnotation(&annotations[idx], by: CGPoint(x: dx, y: dy))
            needsDisplay = true
            return
        }

        // 拖画草稿
        guard selectedTool != .select, selectedTool != .text else { return }
        dragCurrent = n
        updateDraft(to: n)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        movingID = nil
        guard selectedTool != .select, selectedTool != .text,
              let start = dragStart else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let n = normalizedPoint(loc)

        // 太小的丢弃（误触）
        let rect = rectFrom(start, n)
        if rect.width < 0.008 || rect.height < 0.008 {
            draft = nil
            needsDisplay = true
            return
        }

        pushUndo()
        if let d = draft {
            annotations.append(d)
            selectedID = d.id
        }
        draft = nil
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        // ⌘Z 撤销 / ⌘⇧Z 重做（重做第一版省略，仅撤销）
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            undo()
            return
        }
        switch event.keyCode {
        case 53:   // Esc → 选字模式优先退出选字；否则取消（零残留）
            if ocrMode { exitOCRMode() } else { controller?.cancel() }
        case 36, 76:  // Enter / 小回车 → 复制 + 保存（默认动作）
            controller?.copyAndConfirm()
        case 51:   // Delete → 删除选中
            deleteSelected()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 文字就地输入

    private var editingTextView: NSTextView?
    private var editingTextScrollView: NSScrollView?
    private var editingItemID: AnnotationItem.ID?
    private var editingTextTopY: CGFloat = 0
    private var editingTextMinimumHeight: CGFloat = 48

    /// 供控制器的焦点守护判断：文字输入期间必须保留系统 field editor 的焦点。
    var isEditingText: Bool { editingTextView != nil }

    /// 切换工具、保存或复制前统一收尾：空内容取消，有内容确认。
    func finishTextEditing() {
        endTextEditing(commit: true)
    }

    private func beginTextPlacement(at viewPoint: CGPoint) {
        let n = normalizedPoint(viewPoint)
        pushUndo()
        let item = AnnotationItem(
            tool: .text,
            rect: CGRect(x: n.x, y: max(0, n.y - 0.02), width: 0.3, height: 0.06),
            points: [],
            swatch: selectedSwatch,
            strokeWidth: strokeWidth,
            text: ""
        )
        annotations.append(item)
        selectedID = item.id
        beginTextEditing(item: item, at: viewPoint)
        needsDisplay = true
    }

    #if DEBUG
    /// 交互体检入口：不需要屏幕录制权限，在测试图中心打开真实文字输入框。
    func beginTextInputForAudit() {
        guard ProcessInfo.processInfo.arguments.contains("--audit-confirm-text") else { return }
        selectedTool = .text
        window?.makeKeyAndOrderFront(nil)
        beginTextPlacement(at: CGPoint(x: imageDrawRect.midX, y: imageDrawRect.midY))
    }
    #endif

    /// 在点击位置弹出多行输入框。回车换行，⌘↩ 或切换工具完成；留空则放弃放置。
    private func beginTextEditing(item: AnnotationItem, at viewPoint: CGPoint) {
        endTextEditing(commit: true)

        let imageRect = imageDrawRect.insetBy(dx: 8, dy: 8)
        let maximumWidth = max(1, imageRect.width)
        let minimumWidth = min(280, maximumWidth)
        let editorWidth = min(max(minimumWidth, imageRect.width * 0.72), min(720, maximumWidth))
        let editorX = min(max(viewPoint.x, imageRect.minX), max(imageRect.minX, imageRect.maxX - editorWidth))
        let fontSize = AnnotationTextMetrics.viewFontSize(
            lineHeight: item.textLineHeight,
            imageFrameHeight: imageDrawRect.height
        )
        let font = item.resolvedFont(size: fontSize)
        let minimumHeight = min(max(52, ceil(fontSize * 1.8)), max(1, imageRect.height))
        let topY = min(
            max(viewPoint.y + fontSize * 0.55, imageRect.minY + minimumHeight),
            imageRect.maxY
        )

        let scrollView = NSScrollView(frame: NSRect(
            x: editorX,
            y: topY - minimumHeight,
            width: editorWidth,
            height: minimumHeight
        ))
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 7
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.black.withAlphaComponent(0.22).cgColor
        scrollView.layer?.masksToBounds = true

        let textView = ConfirmMultilineTextView(frame: scrollView.contentView.bounds)
        textView.delegate = self
        textView.font = font
        textView.textColor = .black
        textView.insertionPointColor = .systemBlue
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 9, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.placeholderString = "输入文字 · 回车换行 · ⌘↩ 完成"
        textView.onFinish = { [weak self] in self?.finishTextEditing() }
        textView.setAccessibilityLabel("截图文字输入")
        textView.setAccessibilityIdentifier("RuneConfirmTextEditor")

        scrollView.documentView = textView
        addSubview(scrollView)
        editingTextView = textView
        editingTextScrollView = scrollView
        editingItemID = item.id
        editingTextTopY = topY
        editingTextMinimumHeight = minimumHeight
        updateEditingTextLayout()
        window?.makeFirstResponder(textView)
    }

    private func endTextEditing(commit: Bool) {
        guard let textView = editingTextView else { return }
        let scrollView = editingTextScrollView
        let id = editingItemID
        let rawText = textView.string
        let contentSize = measuredEditingTextSize(textView)
        let textOriginX = (scrollView?.frame.minX ?? imageDrawRect.minX) + textView.textContainerInset.width
        let textTopY = editingTextTopY - textView.textContainerInset.height

        editingTextView = nil
        editingTextScrollView = nil
        editingItemID = nil

        if commit, let id,
           let idx = annotations.firstIndex(where: { $0.id == id }) {
            let meaningfulText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if meaningfulText.isEmpty {
                annotations.remove(at: idx)
                if selectedID == id { selectedID = nil }
            } else {
                let text = rawText.trimmingCharacters(in: .newlines)
                let imageRect = imageDrawRect
                let width = min(max(contentSize.width + 2, 1), max(1, imageRect.maxX - textOriginX))
                let height = min(max(contentSize.height + 2, 1), max(1, textTopY - imageRect.minY))
                annotations[idx].text = text
                annotations[idx].rect = CGRect(
                    x: min(max((textOriginX - imageRect.minX) / max(imageRect.width, 1), 0), 1),
                    y: min(max((imageRect.maxY - textTopY) / max(imageRect.height, 1), 0), 1),
                    width: min(width / max(imageRect.width, 1), 1),
                    height: min(height / max(imageRect.height, 1), 1)
                )
                selectedID = id
            }
        }
        scrollView?.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func updateEditingTextLayout() {
        guard let textView = editingTextView,
              let scrollView = editingTextScrollView else { return }

        let contentSize = measuredEditingTextSize(textView)
        let desiredHeight = max(editingTextMinimumHeight, ceil(contentSize.height + textView.textContainerInset.height * 2))
        let imageRect = imageDrawRect.insetBy(dx: 8, dy: 8)
        // 从点击位置先向下长；下方放不下时再把顶部往上推，直到用满整块截图。
        // 只有内容超过整张截图高度时才出现滚动条，避免“能输入但成品尾部被截断”。
        let requiredTopY = imageRect.minY + desiredHeight
        if requiredTopY > editingTextTopY {
            editingTextTopY = min(requiredTopY, imageRect.maxY)
        }
        let maximumHeight = max(editingTextMinimumHeight, editingTextTopY - imageRect.minY)
        let visibleHeight = min(desiredHeight, maximumHeight)

        var frame = scrollView.frame
        frame.origin.y = editingTextTopY - visibleHeight
        frame.size.height = visibleHeight
        scrollView.frame = frame

        let documentHeight = max(visibleHeight, desiredHeight)
        textView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: scrollView.contentSize.width, height: documentHeight)
        )
        scrollView.hasVerticalScroller = desiredHeight > visibleHeight + 1
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    private func measuredEditingTextSize(_ textView: NSTextView) -> CGSize {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return CGSize(width: 1, height: editingTextMinimumHeight)
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let font = textView.font ?? NSFont.systemFont(ofSize: AnnotationTextMetrics.minimumFontSize)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return CGSize(
            width: max(ceil(usedRect.width), font.pointSize * 0.6),
            height: max(ceil(usedRect.height), lineHeight)
        )
    }

    // MARK: - 草稿构建

    private func beginDraft(at n: CGPoint) {
        let rect = CGRect(x: n.x, y: n.y, width: 0, height: 0)
        let item: AnnotationItem
        switch selectedTool {
        case .rectangle:
            item = AnnotationItem(tool: .rectangle, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .arrow:
            item = AnnotationItem(tool: .arrow, rect: rect, points: [n, n], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .blur:
            item = AnnotationItem(tool: .blur, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth, redactionDensity: 0.6)
        case .spotlight:
            item = AnnotationItem(tool: .spotlight, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .numberedCircle:
            let next = annotations.filter { $0.tool == .numberedCircle }.count + 1
            item = AnnotationItem(tool: .numberedCircle, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth, text: "\(next)")
        default:
            return
        }
        draft = item
    }

    private func updateDraft(to n: CGPoint) {
        guard var d = draft else { return }
        switch d.tool {
        case .rectangle, .blur, .spotlight:
            d.rect = rectFrom(dragStart ?? n, n)
        case .arrow:
            d.points = [dragStart ?? n, n]
            d.rect = rectFrom(dragStart ?? n, n)
        case .numberedCircle:
            d.rect = rectFrom(dragStart ?? n, n)
        default:
            break
        }
        draft = d
    }

    private func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 平移标注（rect 与 points 一起挪）。
    private func shiftAnnotation(_ item: inout AnnotationItem, by delta: CGPoint) {
        item.rect.origin.x += delta.x
        item.rect.origin.y += delta.y
        item.points = item.points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
    }

    // MARK: - 工具栏动作（复制 / 贴图）

    /// 在截图确认台后台理解文字、链接、二维码和敏感信息。
    /// 识别期间截图仍可正常保存或复制；结果只改变“内容”菜单。
    func beginContentAnalysis(force: Bool = false) {
        if contentAnalysisTask != nil, !force { return }
        contentAnalysisTask?.cancel()
        contentAnalysisState = .analyzing
        postContentAnalysisChange()

        let sourceImage = image
        contentAnalysisTask = Task { @MainActor [weak self] in
            do {
                let analysis = try await OCRService.shared.analyzeCapture(in: sourceImage)
                guard !Task.isCancelled, let self else { return }
                self.contentAnalysisState = analysis.isEmpty ? .empty : .ready(analysis)
                self.contentAnalysisTask = nil
                self.postContentAnalysisChange()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.contentAnalysisState = .failed
                self.contentAnalysisTask = nil
                self.postContentAnalysisChange()
            }
        }
    }

    func cancelContentAnalysis() {
        contentAnalysisTask?.cancel()
        contentAnalysisTask = nil
    }

    /// 把自动识别到的手机号、邮箱、身份证号直接变成可撤销的打码标注。
    @discardableResult
    func redactDetectedSensitiveContent() -> Int {
        guard case let .ready(analysis) = contentAnalysisState else { return 0 }
        var additions: [AnnotationItem] = []
        for match in analysis.sensitiveMatches {
            let box = match.boundingBox
            let rect = CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            let alreadyRedacted = annotations.contains { item in
                item.tool == .blur && Self.nearlyEqual(item.rect, rect)
            } || additions.contains { item in
                item.tool == .blur && Self.nearlyEqual(item.rect, rect)
            }
            guard !alreadyRedacted else { continue }
            additions.append(AnnotationItem(
                tool: .blur,
                rect: rect,
                points: [],
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                redactionDensity: 0.55
            ))
        }
        guard !additions.isEmpty else { return 0 }
        pushUndo()
        annotations.append(contentsOf: additions)
        selectedID = nil
        needsDisplay = true
        postCanvasStateChange()
        return additions.count
    }

    private static func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.002
        return abs(lhs.minX - rhs.minX) < tolerance
            && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }

    /// 「识别文字」→ 选字模式：识别出带位置的文字块，点选/划选复制（钉钉式）。
    /// 再次调用或 Esc 退出选字，回到标注模式。
    func toggleOCRMode(onDone: @escaping (String) -> Void) {
        finishTextEditing()
        if ocrMode {
            exitOCRMode()
            return
        }
        if case let .ready(analysis) = contentAnalysisState,
           !analysis.observations.isEmpty {
            enterOCRMode(with: analysis.observations, onDone: onDone)
            return
        }
        let cg = image
        onDone("识别中…（约 1-3 秒）")
        Task { @MainActor in
            guard let observations = try? await OCRService.shared.recognizeWithPositions(in: cg),
                  !observations.isEmpty else {
                onDone("未识别到文字")
                return
            }
            enterOCRMode(with: observations, onDone: onDone)
        }
    }

    private func enterOCRMode(
        with observations: [OCRTextObservation],
        onDone: @escaping (String) -> Void
    ) {
        let r = imageDrawRect
        // Vision boundingBox：归一化、原点左下（Y 向上）→ 视图坐标
        ocrBlocks = observations.map { obs in
            let b = obs.boundingBox
            return (
                text: obs.text,
                frame: CGRect(
                    x: r.minX + b.minX * r.width,
                    y: r.minY + b.minY * r.height,
                    width: b.width * r.width,
                    height: b.height * r.height
                )
            )
        }
        ocrMode = true
        selectedTool = .select
        selectedID = nil
        installOCRMontior()
        refreshCursor()
        needsDisplay = true
        postCanvasStateChange()
        onDone("选字模式：点一块复制一块，拖动选一段；Esc 退出")
    }

    /// 拖动/松开事件的队列级兜底：实测选字模式下 mouseDragged/mouseUp
    /// 派发给视图不稳定（mouseDown 必到、后两者经常丢）。
    /// local monitor 在事件出队时即可拿到，不依赖视图派发：
    /// dragged → 实时更新划选矩形（跨行高亮预览）；up → 划选收尾复制。
    private var ocrMouseMonitor: Any?
    /// 已完成的选中（复制后保留显示，直到下一次点选或退出）
    private var ocrSelectedRect: CGRect?

    private func installOCRMontior() {
        removeOCRMonitor()
        ocrMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, self.ocrMode, let start = self.ocrDragStart else { return event }
            let loc = self.convert(event.locationInWindow, from: nil)
            switch event.type {
            case .leftMouseDragged:
                self.ocrDragRect = CGRect(
                    x: min(start.x, loc.x), y: min(start.y, loc.y),
                    width: abs(loc.x - start.x), height: abs(loc.y - start.y)
                )
                self.needsDisplay = true
            case .leftMouseUp:
                self.handleOCRSelectionEnd(at: loc)
            default:
                break
            }
            return event
        }
    }

    private func removeOCRMonitor() {
        if let ocrMouseMonitor {
            NSEvent.removeMonitor(ocrMouseMonitor)
        }
        ocrMouseMonitor = nil
    }

    /// 划选收尾：矩形足够大 → 复制所有相交块（跨行自然支持），选中态保留显示。
    private func handleOCRSelectionEnd(at loc: CGPoint) {
        defer {
            ocrDragStart = nil
            needsDisplay = true
        }
        guard let rect = ocrDragRect, rect.width > 6, rect.height > 6 else {
            ocrDragRect = nil
            return
        }
        let hit = ocrBlocks.filter { !$0.frame.intersection(rect).isNull }
        guard !hit.isEmpty else { return }
        ocrSelectedRect = rect   // 保留选中态，直到下次点选/退出
        copyBlocks(hit)
        ToastWindow.shared.show(
            title: "文字识别",
            message: "已复制 \(hit.count) 块文字",
            systemIcon: "doc.on.doc"
        )
    }

    func exitOCRMode() {
        ocrMode = false
        ocrBlocks = []
        ocrDragStart = nil
        ocrDragRect = nil
        ocrSelectedRect = nil
        removeOCRMonitor()
        refreshCursor()
        needsDisplay = true
        postCanvasStateChange()
    }

    /// 复制选中块文字（按阅读顺序：从上到下、从左到右）
    private func copyBlocks(_ blocks: [(text: String, frame: CGRect)], onDone: ((String) -> Void)? = nil) {
        guard !blocks.isEmpty else { return }
        let sorted = blocks.sorted { a, b in
            abs(a.frame.midY - b.frame.midY) > 8
                ? a.frame.midY > b.frame.midY
                : a.frame.minX < b.frame.minX
        }
        let text = sorted.map(\.text).joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 渲染"截图+标注"成品（复用 BeautifierRenderer 的标注烘焙）。
    /// 用用户设置的美化配置（与保存链一致——此前写死默认值，贴图/复制会和保存效果不一致）。
    func renderedImage() -> CGImage? {
        finishTextEditing()
        let config = AppPreferences.defaultBeautifierConfig
        return BeautifierRenderer.render(image: image, config: config, annotations: annotations)
    }

    /// 复制到剪贴板（含标注）。
    func copyImageToPasteboard() {
        guard let cg = renderedImage() else { return }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
    }

    /// 钉为贴图（含标注），随后结束确认（不落历史文件）。
    func pinImage() {
        guard let cg = renderedImage() else { return }
        // PinnedScreenshotController.pin 吃 URL；写临时文件喂它
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Rune_贴图_\(Int(Date().timeIntervalSince1970 * 1000)).png")
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            _ = CGImageDestinationFinalize(dest)
            PinnedScreenshotController.shared.pin(url: url, on: screen)
            // 贴图后清理临时文件（pin 内部会读入内存）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

// MARK: - 多行文字输入代理：内容实时撑高；失去焦点时空内容丢弃、有内容确认。
extension ConfirmCanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView === editingTextView else { return }
        updateEditingTextLayout()
    }

    func textDidEndEditing(_ notification: Notification) {
        endTextEditing(commit: true)
    }
}

private final class ConfirmMultilineTextView: NSTextView {
    var placeholderString = ""
    var onFinish: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, event.modifierFlags.contains(.command) {
            onFinish?()
            return
        }
        if event.keyCode == 53 {
            onFinish?()
            return
        }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        NSAttributedString(string: placeholderString, attributes: attributes).draw(
            at: CGPoint(x: textContainerInset.width, y: textContainerInset.height)
        )
    }
}
