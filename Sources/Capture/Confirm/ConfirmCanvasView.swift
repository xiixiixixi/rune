import AppKit
import QuartzCore

extension Notification.Name {
    static let confirmCanvasStateDidChange = Notification.Name("Rune.ConfirmCanvasStateDidChange")
    static let confirmCaptureContentDidChange = Notification.Name("Rune.ConfirmCaptureContentDidChange")
}

/// 确认模式画布：显示截图 + 就地标注（拖画/选中/移动/删除）。
///
/// 复用 AnnotationItem 模型（0-1 归一化、Y-down）与 AnnotationDrawing 烘焙渲染。
/// 键盘（没有编辑文字时）：Esc=取消、Enter=回车默认动作（出厂仅复制）、
/// ⇧⌘Enter=复制并保存、⌘S=保存、⌘Z=撤销、Delete=删除选中。
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
    private var redoStack: [[AnnotationItem]] = []

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

    // MARK: - 选区再调整（Snipaste 式：确认态拖角/边改选区）
    //
    // cropRect 为 nil 表示未调整（选区=原图范围）。有整屏定格帧时可向外扩
    // （像素从定格帧取），否则（长图等）只能向内缩。

    private enum CropHandle {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private var cropRect: CGRect?
    private var resizingHandle: CropHandle?
    // 拖动整个选区（选择工具下点选区内部空白处）
    private var movingCrop = false
    private var cropMoveStart: CGPoint?
    private var cropMoveOrigin: CGRect?

    /// ⌥ 在选区内按下：待命把成品拖出去。移动超过阈值才真的开拖拽会话，
    /// 这样"⌥ 点一下"不会误触发拖拽。
    private var dragOutOrigin: CGPoint?

    /// 当前生效的选区（视图坐标）。
    var effectiveCropRect: CGRect {
        cropRect ?? imageDrawRect
    }

    /// 选区允许的活动范围：有整屏定格帧=整屏；否则=原图区域。
    private var cropAllowedBounds: CGRect {
        backgroundImage != nil ? bounds : imageDrawRect
    }

    private func cropHandle(at p: CGPoint) -> CropHandle? {
        guard selectedTool == .select, !ocrMode else { return nil }
        let c = effectiveCropRect
        let tolerance: CGFloat = 9
        let nearLeft = abs(p.x - c.minX) <= tolerance
        let nearRight = abs(p.x - c.maxX) <= tolerance
        let nearBottom = abs(p.y - c.minY) <= tolerance
        let nearTop = abs(p.y - c.maxY) <= tolerance
        let withinY = p.y >= c.minY - tolerance && p.y <= c.maxY + tolerance
        let withinX = p.x >= c.minX - tolerance && p.x <= c.maxX + tolerance
        // 角优先，其次边
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearLeft && withinY { return .left }
        if nearRight && withinY { return .right }
        if nearTop && withinX { return .top }
        if nearBottom && withinX { return .bottom }
        return nil
    }

    private func applyCropResize(to location: CGPoint) {        let limit = cropAllowedBounds
        let p = CGPoint(
            x: min(max(location.x, limit.minX), limit.maxX),
            y: min(max(location.y, limit.minY), limit.maxY)
        )
        let c = cropRect ?? imageDrawRect
        let minSize: CGFloat = 24
        var x0 = c.minX, y0 = c.minY, x1 = c.maxX, y1 = c.maxY
        switch resizingHandle {
        case .left: x0 = min(p.x, x1 - minSize)
        case .right: x1 = max(p.x, x0 + minSize)
        case .bottom: y0 = min(p.y, y1 - minSize)
        case .top: y1 = max(p.y, y0 + minSize)
        case .bottomLeft: x0 = min(p.x, x1 - minSize); y0 = min(p.y, y1 - minSize)
        case .bottomRight: x1 = max(p.x, x0 + minSize); y0 = min(p.y, y1 - minSize)
        case .topLeft: x0 = min(p.x, x1 - minSize); y1 = max(p.y, y0 + minSize)
        case .topRight: x1 = max(p.x, x0 + minSize); y1 = max(p.y, y0 + minSize)
        case nil: return
        }
        let clamped = CGRect(
            x: x0, y: y0, width: x1 - x0, height: y1 - y0
        ).intersection(limit)
        guard clamped.width >= minSize * 0.5, clamped.height >= minSize * 0.5 else { return }
        cropRect = clamped
        notifyToolbarFollow()
        needsDisplay = true
    }

    /// 拖动整个选区：位移钳制在允许范围内（有定格帧=整屏，否则=原图区域）。
    private func applyCropMove(to location: CGPoint) {
        guard let start = cropMoveStart, let origin = cropMoveOrigin else { return }
        let limit = cropAllowedBounds
        let dx = min(
            max(location.x - start.x, limit.minX - origin.minX),
            limit.maxX - origin.maxX
        )
        let dy = min(
            max(location.y - start.y, limit.minY - origin.minY),
            limit.maxY - origin.maxY
        )
        cropRect = origin.offsetBy(dx: dx, dy: dy)
        notifyToolbarFollow()
        needsDisplay = true
    }

    /// 选区变了：悬浮工具栏跟着选区重新落位（下方 → 上方 → 屏幕底部）。
    private func notifyToolbarFollow() {
        let c = effectiveCropRect
        controller?.relayoutToolbar(near: CGRect(
            x: screen.frame.minX + c.minX,
            y: screen.frame.minY + c.minY,
            width: c.width,
            height: c.height
        ))
    }

    /// 选区调整后的成图（nil = 未调整）。有整屏定格帧时向外扩的像素从定格帧取。
    func croppedImage() -> CGImage? {
        guard let cropRect else { return nil }
        let c = cropRect.intersection(cropAllowedBounds)
        guard c.width > 4, c.height > 4 else { return nil }
        if let backgroundImage {
            let scaleX = CGFloat(backgroundImage.width) / max(bounds.width, 1)
            let scaleY = CGFloat(backgroundImage.height) / max(bounds.height, 1)
            let pixelRect = CGRect(
                x: c.minX * scaleX,
                y: (bounds.height - c.maxY) * scaleY,
                width: c.width * scaleX,
                height: c.height * scaleY
            ).integral
            guard pixelRect.minX >= 0, pixelRect.minY >= 0,
                  pixelRect.maxX <= CGFloat(backgroundImage.width),
                  pixelRect.maxY <= CGFloat(backgroundImage.height) else { return nil }
            return backgroundImage.cropping(to: pixelRect)
        }
        let r = imageDrawRect
        let intersection = c.intersection(r)
        guard !intersection.isNull, intersection.width > 4, intersection.height > 4 else {
            return nil
        }
        let scaleX = CGFloat(image.width) / max(r.width, 1)
        let scaleY = CGFloat(image.height) / max(r.height, 1)
        let pixelRect = CGRect(
            x: (intersection.minX - r.minX) * scaleX,
            y: (r.maxY - intersection.maxY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        ).integral
        guard pixelRect.minX >= 0, pixelRect.minY >= 0,
              pixelRect.maxX <= CGFloat(image.width),
              pixelRect.maxY <= CGFloat(image.height) else { return nil }
        return image.cropping(to: pixelRect)
    }

    /// 标注从原图归一化坐标重映射到裁剪后选区（完全落在选区外的丢弃）。
    func remappedAnnotations() -> [AnnotationItem] {
        let crop = effectiveCropRect
        guard cropRect != nil, crop.width > 1, crop.height > 1 else { return annotations }
        let r = imageDrawRect
        func mapPoint(_ p: CGPoint) -> CGPoint {
            let viewX = r.minX + p.x * r.width
            let viewY = r.maxY - p.y * r.height
            return CGPoint(
                x: (viewX - crop.minX) / crop.width,
                y: (crop.maxY - viewY) / crop.height
            )
        }
        var result: [AnnotationItem] = []
        for var item in annotations {
            let topLeft = mapPoint(CGPoint(x: item.rect.minX, y: item.rect.minY))
            let bottomRight = mapPoint(CGPoint(x: item.rect.maxX, y: item.rect.maxY))
            item.rect = CGRect(
                x: min(topLeft.x, bottomRight.x),
                y: min(topLeft.y, bottomRight.y),
                width: abs(bottomRight.x - topLeft.x),
                height: abs(bottomRight.y - topLeft.y)
            )
            item.points = item.points.map(mapPoint)
            if item.rect.maxX >= 0, item.rect.minX <= 1,
               item.rect.maxY >= 0, item.rect.minY <= 1 {
                result.append(item)
            }
        }
        return result
    }

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
        redoStack.append(annotations)
        annotations = undoStack.removeLast()
        selectedID = nil
        needsDisplay = true
        postCanvasStateChange()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func redo() {
        guard !redoStack.isEmpty else { return }
        undoStack.append(annotations)
        annotations = redoStack.removeLast()
        selectedID = nil
        needsDisplay = true
        postCanvasStateChange()
    }

    var canRedo: Bool { !redoStack.isEmpty }

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
        let wasNumbered = annotations.first(where: { $0.id == id })?.tool == .numberedCircle
        annotations.removeAll { $0.id == id }
        selectedID = nil
        if wasNumbered {
            renumberCircleAnnotations()
        }
        needsDisplay = true
    }

    private func pushUndo() {
        undoStack.append(annotations)
        redoStack.removeAll()
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
        let drawRect = effectiveCropRect
        ctx.draw(image, in: imageDrawRect)
        ctx.restoreGState()

        // 2.5 选区调整后：选区外压暗，让"什么会被裁掉"一目了然。
        if cropRect != nil {
            let c = drawRect
            let outside = [
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, c.minY - bounds.minY)),
                CGRect(x: bounds.minX, y: c.maxY, width: bounds.width, height: max(0, bounds.maxY - c.maxY)),
                CGRect(x: bounds.minX, y: c.minY, width: max(0, c.minX - bounds.minX), height: c.height),
                CGRect(x: c.maxX, y: c.minY, width: max(0, bounds.maxX - c.maxX), height: c.height),
            ]
            NSColor.black.withAlphaComponent(0.38).setFill()
            for rect in outside where rect.width > 0.5 && rect.height > 0.5 {
                rect.fill()
            }
        }

        // 3. 只保留细边界标识选区；选区外维持原始亮度。
        drawFrozenEdge(around: drawRect)
        drawCropHandles(around: drawRect)

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

        // 4. 画标注（归一化坐标映射到 imageDrawRect；Y-down → CG 用 flipped 渲染）。
        // 注意锚点必须是 imageDrawRect（与 normalizedPoint/viewRect 同一坐标系）——
        // 选区框（effectiveCropRect）只决定最终裁剪输出，不能参与编辑坐标，
        // 否则选区一挪/一缩，画出的框就会偏移到别处。
        // 马赛克草稿特殊处理：AnnotationDrawing 的 blur 需要画布快照（此处没有），
        // 拖拽阶段由本视图直接画棋盘格预览（选中即见"这是打码"），保存烘焙才是真马赛克
        var items = annotations
        if let draft {
            if draft.tool.isRedactionTool, draft.rect.width > 0.003, draft.rect.height > 0.003 {
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
            ctx.translateBy(x: 0, y: imageDrawRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let flippedRect = CGRect(
                x: imageDrawRect.minX,
                y: 0,
                width: imageDrawRect.width,
                height: imageDrawRect.height
            )
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

        // 5. 悬停高亮 + 选中装饰（capcap 式：红虚线框 + 8 向缩放句柄 +
        // 箭头/直线端点圆 + 右上角删除按钮）
        if let hoveredID = hoveredAnnotationID,
           hoveredID != selectedID,
           let hovered = annotations.first(where: { $0.id == hoveredID }) {
            let r = viewRect(for: hovered.bounds).insetBy(dx: -3, dy: -3)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
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

            // 句柄：矩形类 8 向方块；箭头/直线首尾端点圆
            if item.tool == .arrow || item.tool == .line {
                for anchor in annotationHandleAnchors(item) {
                    let radius: CGFloat = 5
                    let dot = CGRect(
                        x: anchor.point.x - radius,
                        y: anchor.point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.setStrokeColor(NSColor.systemRed.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.fillEllipse(in: dot)
                    ctx.strokeEllipse(in: dot)
                }
            } else if item.tool != .freehand && item.tool != .text {
                let hs: CGFloat = 7
                for anchor in annotationHandleAnchors(item) {
                    guard case .rectAnchor = anchor.handle else { continue }
                    let rect = CGRect(
                        x: anchor.point.x - hs / 2,
                        y: anchor.point.y - hs / 2,
                        width: hs,
                        height: hs
                    )
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.setStrokeColor(NSColor.systemRed.cgColor)
                    ctx.setLineWidth(1.5)
                    ctx.fill(rect)
                    ctx.stroke(rect)
                }
            }

            // 删除按钮：右上角小圆 ×；编号标注在下方再给 +/− 步进（capcap 式）
            let button = deleteButtonRect(for: item)
            var actionButtons: [(rect: CGRect, glyph: Glyph)] = [(button, .cross)]
            if item.tool == .numberedCircle {
                actionButtons.append((numberStepButtonRect(for: item, increment: true), .plus))
                actionButtons.append((numberStepButtonRect(for: item, increment: false), .minus))
            }
            for (rect, glyph) in actionButtons {
                let circle = CGRect(
                    x: rect.midX - 9, y: rect.midY - 9, width: 18, height: 18
                )
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: circle)
                let arm: CGFloat = 3.4
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                switch glyph {
                case .cross:
                    ctx.move(to: CGPoint(x: rect.midX - arm, y: rect.midY - arm))
                    ctx.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY + arm))
                    ctx.move(to: CGPoint(x: rect.midX - arm, y: rect.midY + arm))
                    ctx.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY - arm))
                case .plus, .minus:
                    ctx.move(to: CGPoint(x: rect.midX - arm, y: rect.midY))
                    ctx.addLine(to: CGPoint(x: rect.midX + arm, y: rect.midY))
                    if case .plus = glyph {
                        ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - arm))
                        ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + arm))
                    }
                }
                ctx.strokePath()
            }
        }
    }

    private enum Glyph {
        case cross, plus, minus
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
        // 长图（滚动截图等）：整幅按屏幕比例自适应，而不是按原始点尺寸居中——
        // 一张数千点高的长图居中摆放时两头都画在屏幕外，用户只能看到中段。
        // 底部留出确认工具栏的空间。
        if pointSize.width > bounds.width || pointSize.height > bounds.height {
            let horizontalMargin: CGFloat = 28
            let topMargin: CGFloat = 28
            let bottomMargin: CGFloat = 104
            let availableWidth = bounds.width - horizontalMargin * 2
            let availableHeight = bounds.height - topMargin - bottomMargin
            guard availableWidth > 10, availableHeight > 10 else {
                return CGRect(
                    x: bounds.midX - pointSize.width / 2,
                    y: bounds.midY - pointSize.height / 2,
                    width: pointSize.width,
                    height: pointSize.height
                )
            }
            let fitScale = min(
                availableWidth / pointSize.width,
                availableHeight / pointSize.height
            )
            let fittedSize = CGSize(
                width: pointSize.width * fitScale,
                height: pointSize.height * fitScale
            )
            return CGRect(
                x: bounds.midX - fittedSize.width / 2,
                y: bottomMargin + (availableHeight - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        }
        return CGRect(
            x: bounds.midX - pointSize.width / 2,
            y: bounds.midY - pointSize.height / 2,
            width: pointSize.width,
            height: pointSize.height
        )
    }

    /// 选区再调整句柄：选择工具下在四角/四边画白色圆点，提示可拖动。
    private func drawCropHandles(around rect: CGRect) {
        guard selectedTool == .select, !ocrMode else { return }
        let radius: CGFloat = 4.5
        let centers = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
        ]
        for center in centers {
            let halo = NSBezierPath(
                ovalIn: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            NSColor.black.withAlphaComponent(0.35).setFill()
            halo.fill()
            let dot = NSBezierPath(
                ovalIn: CGRect(
                    x: center.x - radius + 1,
                    y: center.y - radius + 1,
                    width: radius * 2 - 2,
                    height: radius * 2 - 2
                )
            )
            NSColor.white.setFill()
            dot.fill()
        }
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

    // MARK: - 单标注交互（capcap 式：任何工具下点中标注先拖动；选中后
    // 缩放句柄/端点重抓/删除按钮/悬停高亮；方向键微调；标注剪贴板）

    private enum AnnotationHandle {
        /// 0=左上 1=上中 2=右上 3=右中 4=右下 5=下中 6=左下 7=左中（归一化 Y-down 语义）
        case rectAnchor(Int)
        case endpointStart
        case endpointEnd
    }

    private var annotationHandleDrag: AnnotationHandle?
    private var handleDragOriginal: AnnotationItem?
    private var hoveredAnnotationID: AnnotationItem.ID?
    private var lastMouseLocation: CGPoint?
    private var movedOnceDuringDrag = false
    /// 标注剪贴板（跨截图会话可用）：⌘C/⌘X 复制，⌘V 原位偏移粘贴
    private static var annotationClipboard: [AnnotationItem] = []

    /// 视图坐标点（y-up）→ 归一化点（y-down，不夹取）
    private func normalizedPointRaw(_ p: CGPoint) -> CGPoint {
        let r = imageDrawRect
        return CGPoint(
            x: (p.x - r.minX) / max(r.width, 1),
            y: (r.maxY - p.y) / max(r.height, 1)
        )
    }

    /// 归一化点（y-down）→ 视图坐标点（y-up）
    private func viewPoint(fromNormalized p: CGPoint) -> CGPoint {
        let r = imageDrawRect
        return CGPoint(x: r.minX + p.x * r.width, y: r.maxY - p.y * r.height)
    }

    private func annotationHit(at loc: CGPoint) -> AnnotationItem? {
        let n = normalizedPoint(loc)
        return annotations.last { item in
            item.bounds.insetBy(dx: -0.008, dy: -0.008).contains(n)
        }
    }

    /// 标注的句柄锚点（视图坐标）：矩形类 8 向 + 箭头/直线首尾端点。
    private func annotationHandleAnchors(_ item: AnnotationItem) -> [(handle: AnnotationHandle, point: CGPoint)] {
        if item.tool == .arrow || item.tool == .line,
           item.points.count >= 2 {
            return [
                (.endpointStart, viewPoint(fromNormalized: item.points[0])),
                (.endpointEnd, viewPoint(fromNormalized: item.points[item.points.count - 1])),
            ]
        }
        let vr = viewRect(for: item.bounds)
        let anchors: [(Int, CGPoint)] = [
            (0, CGPoint(x: vr.minX, y: vr.maxY)),   // 左上（视图 y-up）
            (1, CGPoint(x: vr.midX, y: vr.maxY)),
            (2, CGPoint(x: vr.maxX, y: vr.maxY)),
            (3, CGPoint(x: vr.maxX, y: vr.midY)),
            (4, CGPoint(x: vr.maxX, y: vr.minY)),   // 右下
            (5, CGPoint(x: vr.midX, y: vr.minY)),
            (6, CGPoint(x: vr.minX, y: vr.minY)),
            (7, CGPoint(x: vr.minX, y: vr.midY)),
        ]
        return anchors.map { (.rectAnchor($0.0), $0.1) }
    }

    private func annotationHandle(at loc: CGPoint, item: AnnotationItem) -> AnnotationHandle? {
        let tolerance: CGFloat = 9
        for anchor in annotationHandleAnchors(item)
        where hypot(anchor.point.x - loc.x, anchor.point.y - loc.y) <= tolerance {
            return anchor.handle
        }
        return nil
    }

    /// 选中标注右上角的删除按钮（小圆 × ）。
    private func deleteButtonRect(for item: AnnotationItem) -> CGRect {
        let vr = viewRect(for: item.bounds)
        let side: CGFloat = 20
        return CGRect(
            x: vr.maxX + 6,
            y: vr.maxY - side,
            width: side,
            height: side
        )
    }

    /// 选中编号标注的 ± 步进按钮（capcap 式：直接调编号，删号后手动补齐）。
    private func numberStepButtonRect(for item: AnnotationItem, increment: Bool) -> CGRect {
        let vr = viewRect(for: item.bounds)
        let side: CGFloat = 20
        let row: CGFloat = increment ? 2 : 3   // 删除按钮为第 1 行
        let y = vr.maxY - side * row - CGFloat(row - 1) * 4
        return CGRect(x: vr.maxX + 6, y: y, width: side, height: side)
    }

    private func adjustNumberedCircle(_ item: AnnotationItem, by delta: Int) {
        guard let idx = annotations.firstIndex(where: { $0.id == item.id }) else { return }
        let current = Int(annotations[idx].text) ?? 1
        let next = min(999, max(1, current + delta))
        pushUndo()
        annotations[idx].text = "\(next)"
        needsDisplay = true
    }

    /// 下一个编号 = 当前最大编号 + 1（删除中间号后再画不会重号）。
    private var nextCircleNumber: Int {
        (annotations
            .filter { $0.tool == .numberedCircle }
            .compactMap { Int($0.text) }
            .max() ?? 0) + 1
    }

    /// 删除编号后整体重排（保持 1…N 连续，capcap 计数器同步同款语义）。
    private func renumberCircleAnnotations() {
        var number = 1
        for index in annotations.indices where annotations[index].tool == .numberedCircle {
            annotations[index].text = "\(number)"
            number += 1
        }
    }

    private func applyAnnotationHandleDrag(to loc: CGPoint) {
        guard let handle = annotationHandleDrag,
              let id = selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }),
              let original = handleDragOriginal else { return }
        let r = imageDrawRect
        let minNx = 12 / max(r.width, 1)
        let minNy = 12 / max(r.height, 1)
        var item = annotations[idx]
        let n = normalizedPoint(loc)

        switch handle {
        case .rectAnchor(let anchor):
            guard item.tool != .freehand else { return }
            let o = original.rect
            var x0 = o.minX, y0 = o.minY, x1 = o.maxX, y1 = o.maxY
            // 归一化 Y-down：y0=顶、y1=底
            switch anchor {
            case 0: x0 = n.x; y0 = n.y
            case 1: y0 = n.y
            case 2: x1 = n.x; y0 = n.y
            case 3: x1 = n.x
            case 4: x1 = n.x; y1 = n.y
            case 5: y1 = n.y
            case 6: x0 = n.x; y1 = n.y
            case 7: x0 = n.x
            default: return
            }
            let rect = CGRect(
                x: min(x0, x1), y: min(y0, y1),
                width: abs(x1 - x0), height: abs(y1 - y0)
            )
            if rect.width >= minNx, rect.height >= minNy {
                item.rect = rect
            }

        case .endpointStart, .endpointEnd:
            guard item.tool == .arrow || item.tool == .line,
                  item.points.count >= 2 else { return }
            if case .endpointStart = handle {
                item.points[0] = n
            } else {
                item.points[item.points.count - 1] = n
            }
            let a = item.points[0]
            let b = item.points[item.points.count - 1]
            item.rect = CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(b.x - a.x), height: abs(b.y - a.y)
            )
        }
        annotations[idx] = item
        needsDisplay = true
    }

    /// 方向键微调选中标注（1pt，Shift = 10pt，capcap 同款）。
    private func nudgeSelectedAnnotation(keyCode: UInt16, shiftHeld: Bool) {
        guard let id = selectedID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let step: CGFloat = shiftHeld ? 10 : 1
        let r = imageDrawRect
        let dx: CGFloat, dy: CGFloat   // 归一化 Y-down
        switch keyCode {
        case 123: dx = -step / max(r.width, 1); dy = 0
        case 124: dx = step / max(r.width, 1); dy = 0
        case 125: dx = 0; dy = step / max(r.height, 1)
        case 126: dx = 0; dy = -step / max(r.height, 1)
        default: return
        }
        pushUndo()
        shiftAnnotation(&annotations[idx], by: CGPoint(x: dx, y: dy))
        needsDisplay = true
    }

    /// 双击文字标注 → 原位重新编辑（取回文字预填）。
    private func reEditTextAnnotation(_ item: AnnotationItem) {
        pushUndo()
        annotations.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = nil }
        beginTextPlacement(
            at: viewPoint(fromNormalized: CGPoint(x: item.rect.minX, y: item.rect.minY)),
            prefill: item.text
        )
    }

    // MARK: - 标注剪贴板

    private func copySelectedAnnotationToClipboard() {
        guard let id = selectedID,
              let item = annotations.first(where: { $0.id == id }) else { return }
        Self.annotationClipboard = [item]
    }

    private func pasteAnnotationsFromClipboard() {
        guard !Self.annotationClipboard.isEmpty else { return }
        pushUndo()
        var pastedIDs: [AnnotationItem.ID] = []
        for (offset, original) in Self.annotationClipboard.enumerated() {
            let dx = CGFloat(2 + offset * 2) * 14 / max(imageDrawRect.width, 1)
            let dy = -CGFloat(2 + offset * 2) * 14 / max(imageDrawRect.height, 1)
            var copy = original
            copy.rect = original.rect.offsetBy(dx: dx, dy: dy)
            copy.points = original.points.map {
                CGPoint(x: $0.x + dx, y: $0.y + dy)
            }
            // 重新生成 id，避免与源标注重复
            copy = AnnotationItem(
                tool: copy.tool,
                rect: copy.rect,
                points: copy.points,
                swatch: copy.swatch,
                strokeWidth: copy.strokeWidth,
                redactionDensity: copy.redactionDensity,
                text: copy.text,
                textLineHeight: copy.textLineHeight,
                fontName: copy.fontName,
                isBold: copy.isBold,
                isItalic: copy.isItalic,
                isUnderline: copy.isUnderline,
                textAlignment: copy.textAlignment
            )
            annotations.append(copy)
            pastedIDs.append(copy.id)
        }
        // 粘贴可能带入编号圆点：整体重排，避免与已有编号重复
        if Self.annotationClipboard.contains(where: { $0.tool == .numberedCircle }) {
            renumberCircleAnnotations()
        }
        selectedID = pastedIDs.last
        needsDisplay = true
    }

    // MARK: - 悬停追踪

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    private var hoverTrackingArea: NSTrackingArea?

    override func mouseMoved(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        lastMouseLocation = loc
        guard !ocrMode, editingTextView == nil,
              annotationHandleDrag == nil, movingID == nil,
              resizingHandle == nil, !movingCrop else { return }
        let hit = imageDrawRect.contains(loc) ? annotationHit(at: loc) : nil
        let newHovered = hit?.id
        guard newHovered != hoveredAnnotationID else { return }
        hoveredAnnotationID = newHovered
        needsDisplay = true
    }


    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        // 点到文字框以外时，先结束上一段文字：空内容丢弃，有内容保留。
        // 这样保持文字工具连续放置时，也不会残留一个失去焦点的输入框。
        finishTextEditing()

        // ⌥ + 在选区内按下 = 把成品拖到别的应用。必须在所有分支之前判定：
        // 选区内的普通拖动归"移动选区框"、点标注归"移动标注"，⌥ 是唯一
        // 不会和它们抢同一段手势的入口。
        if event.modifierFlags.contains(.option), imageDrawRect.contains(loc) {
            dragOutOrigin = loc
            return
        }

        // 选区再调整：选择工具下抓到角/边句柄 → 拖动改选区（角/边命中
        // 区延伸到选区外 9pt，必须在"只许亮区编辑"的守卫之前判定）。
        if let handle = cropHandle(at: loc) {
            cropRect = effectiveCropRect
            resizingHandle = handle
            needsDisplay = true
            return
        }

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

        // capcap 规则：句柄优先于整体拖动——选中标注的角/边句柄必须比
        // "点中标注=移动"先判定，否则拖角永远变成移动，无法改大小。
        if let id = selectedID,
           let item = annotations.first(where: { $0.id == id }) {
            if deleteButtonRect(for: item).contains(loc) {
                deleteSelected()
                return
            }
            if item.tool == .numberedCircle {
                if numberStepButtonRect(for: item, increment: true).contains(loc) {
                    adjustNumberedCircle(item, by: 1)
                    return
                }
                if numberStepButtonRect(for: item, increment: false).contains(loc) {
                    adjustNumberedCircle(item, by: -1)
                    return
                }
            }
            if let handle = annotationHandle(at: loc, item: item) {
                pushUndo()
                handleDragOriginal = item
                annotationHandleDrag = handle
                return
            }
        }

        // capcap 通用规则：点中已有标注 = 选中并拖动它，不管当前是什么工具；
        // 绘图工具只接管空白处的按下。文字标注双击 = 原位重新编辑。
        if !ocrMode, let hit = annotationHit(at: loc) {
            if event.clickCount >= 2, hit.tool == .text {
                reEditTextAnnotation(hit)
                return
            }
            selectedID = hit.id
            movingID = hit.id
            movedOnceDuringDrag = false
            moveOffset = CGPoint(x: n.x - hit.bounds.midX, y: n.y - hit.bounds.midY)
            needsDisplay = true
            return
        }

        // 空白处双击 = 确认（回车默认动作，capcap 同款）
        if event.clickCount >= 2 {
            controller?.confirmWithPreferredAction()
            return
        }

        if selectedTool == .select {
            selectedID = nil
            // 空白处按下：拖动整个选区框（Snipaste 式移动）
            cropRect = effectiveCropRect
            movingCrop = true
            cropMoveStart = loc
            cropMoveOrigin = cropRect
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
            let item = AnnotationItem(
                tool: .numberedCircle,
                rect: CGRect(x: n.x - wNorm / 2, y: n.y - hNorm / 2, width: wNorm, height: hNorm),
                points: [],
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                text: "\(nextCircleNumber)"
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

        // ⌥ 拖出：越过阈值才交给系统拖拽会话（`beginDraggingSession` 一旦
        // 调用，后续 mouseUp 由系统派发，这里不能再动状态）。
        if let origin = dragOutOrigin {
            guard hypot(loc.x - origin.x, loc.y - origin.y) >= 4 else { return }
            dragOutOrigin = nil
            beginImageDragOut(with: event)
            return
        }

        // 选区再调整拖拽
        if resizingHandle != nil {
            applyCropResize(to: loc)
            return
        }
        if movingCrop {
            applyCropMove(to: loc)
            return
        }

        // 标注句柄拖拽（缩放 / 端点重抓）
        if annotationHandleDrag != nil {
            applyAnnotationHandleDrag(to: loc)
            return
        }

        let n = normalizedPoint(loc)

        // 移动标注（capcap 通用规则：任何工具下点中的标注都可拖动；
        // 首次实际移动才入撤销栈，纯点击不留空撤销记录）
        if let id = movingID,
           let idx = annotations.firstIndex(where: { $0.id == id }) {
            if !movedOnceDuringDrag {
                pushUndo()
                movedOnceDuringDrag = true
            }
            let b = annotations[idx].bounds
            let newCenter = CGPoint(x: n.x - moveOffset.x, y: n.y - moveOffset.y)
            let dx = newCenter.x - b.midX
            let dy = newCenter.y - b.midY
            shiftAnnotation(&annotations[idx], by: CGPoint(x: dx, y: dy))
            needsDisplay = true
            return
        }

        // 拖画草稿（Shift = 正方形/正圆/角度吸附）
        guard selectedTool != .select, selectedTool != .text else { return }
        dragCurrent = n
        updateDraft(to: n, shiftConstrained: event.modifierFlags.contains(.shift))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragOutOrigin = nil
        if resizingHandle != nil {
            resizingHandle = nil
            needsDisplay = true
            return
        }
        if movingCrop {
            movingCrop = false
            cropMoveStart = nil
            cropMoveOrigin = nil
            needsDisplay = true
            return
        }
        if annotationHandleDrag != nil {
            annotationHandleDrag = nil
            handleDragOriginal = nil
            postCanvasStateChange()
            needsDisplay = true
            return
        }
        movedOnceDuringDrag = false
        movingID = nil
        guard selectedTool != .select, selectedTool != .text,
              let start = dragStart else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let n = normalizedPoint(loc)

        // 太小的丢弃（误触）——用草稿自身的矩形（含 Shift 约束后的尺寸）
        let rect = draft?.rect ?? rectFrom(start, n)
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
        // ⌘Z 撤销 / 裸 Z 重做（capcap 同款）
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            undo()
            return
        }
        // ⌘S → 保存到文件夹（与工具栏「保存」同效）
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "s" {
            controller?.confirm()
            return
        }
        // ⇧⌘Enter → 复制并保存到文件夹。必须在 keyCode 分支之前拦：
        // 下面的 case 36/76 不区分修饰键，否则会被当成默认动作。
        if event.keyCode == 36 || event.keyCode == 76,
           event.modifierFlags.contains(.command),
           event.modifierFlags.contains(.shift) {
            controller?.copyAndConfirm()
            return
        }
        switch event.keyCode {
        case 53:   // Esc → 选字模式优先退出选字；否则取消（零残留）
            if ocrMode { exitOCRMode() } else { controller?.cancel() }
        case 36, 76:  // Enter / 小回车 → 回车默认动作（出厂仅复制，可在设置里改）
            controller?.confirmWithPreferredAction()
        case 51:   // Delete → 删除选中
            deleteSelected()
        case 123, 124, 125, 126:  // 方向键 → 微调选中标注（1pt，Shift=10pt）
            guard editingTextView == nil else { break }
            nudgeSelectedAnnotation(
                keyCode: event.keyCode,
                shiftHeld: event.modifierFlags.contains(.shift)
            )
        default:
            // 标注剪贴板（capcap 式：⌘C/⌘X/⌘V，跨截图会话可用）
            if editingTextView == nil,
               event.modifierFlags.contains(.command),
               let key = event.charactersIgnoringModifiers?.lowercased(),
               ["c", "x", "v"].contains(key) {
                switch key {
                case "c": copySelectedAnnotationToClipboard()
                case "x":
                    copySelectedAnnotationToClipboard()
                    deleteSelected()
                case "v": pasteAnnotationsFromClipboard()
                default: break
                }
                return
            }
            // 单键快捷键（capcap 式：字母直接切工具/动作）。文字输入期间不生效。
            guard editingTextView == nil,
                  let key = event.charactersIgnoringModifiers?.lowercased(),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  key.count == 1 else {
                super.keyDown(with: event)
                return
            }
            switch key {
            case "v": switchTool(to: .select)
            case "r": switchTool(to: .rectangle)
            case "f": switchTool(to: .filledRectangle)
            case "o": switchTool(to: .ellipse)
            case "l": switchTool(to: .line)
            case "a": switchTool(to: .arrow)
            case "d": switchTool(to: .freehand)
            case "t": switchTool(to: .text)
            case "m": switchTool(to: .blur)
            case "e": switchTool(to: .pixelate)
            case "g": switchTool(to: .spotlight)
            case "n": switchTool(to: .numberedCircle)
            case "z": redo()
            case "p":
                pinImage()
                controller?.cancel()
            case "x":
                controller?.cancel()
            default:
                super.keyDown(with: event)
            }
        }
    }

    /// 键盘切工具：与工具栏点击同效（清选中、换光标、通知工具栏同步高亮）。
    private func switchTool(to tool: AnnotationTool) {
        finishTextEditing()
        selectedTool = tool
        selectedID = nil
        refreshCursor()
        postCanvasStateChange()
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

    private func beginTextPlacement(at viewPoint: CGPoint, prefill: String = "") {
        let n = normalizedPoint(viewPoint)
        pushUndo()
        let item = AnnotationItem(
            tool: .text,
            rect: CGRect(x: n.x, y: max(0, n.y - 0.02), width: 0.3, height: 0.06),
            points: [],
            swatch: selectedSwatch,
            strokeWidth: strokeWidth,
            text: prefill
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
        case .rectangle, .filledRectangle, .ellipse:
            item = AnnotationItem(tool: selectedTool, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .line:
            item = AnnotationItem(tool: .line, rect: rect, points: [n, n], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .arrow:
            item = AnnotationItem(tool: .arrow, rect: rect, points: [n, n], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .freehand:
            item = AnnotationItem(tool: .freehand, rect: rect, points: [n], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .blur:
            item = AnnotationItem(tool: .blur, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth, redactionDensity: 0.6)
        case .pixelate:
            item = AnnotationItem(tool: .pixelate, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth, redactionDensity: 0.55)
        case .spotlight:
            item = AnnotationItem(tool: .spotlight, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth)
        case .numberedCircle:
            item = AnnotationItem(tool: .numberedCircle, rect: rect, points: [], swatch: selectedSwatch, strokeWidth: strokeWidth, text: "\(nextCircleNumber)")
        default:
            return
        }
        draft = item
    }

    private func updateDraft(to n: CGPoint, shiftConstrained: Bool = false) {
        guard var d = draft else { return }
        let target = shiftConstrained ? shiftConstrainedPoint(n, for: d.tool) : n
        switch d.tool {
        case .rectangle, .filledRectangle, .ellipse, .blur, .pixelate, .spotlight, .numberedCircle:
            d.rect = rectFrom(dragStart ?? target, target)
        case .arrow, .line:
            d.points = [dragStart ?? target, target]
            d.rect = rectFrom(dragStart ?? target, target)
        case .freehand:
            // 画笔跟随拖动持续追加轨迹点
            d.points.append(n)
            d.rect = d.rect.union(CGRect(x: n.x, y: n.y, width: 0, height: 0))
        default:
            break
        }
        draft = d
    }

    /// Shift 约束（归一化坐标，需先换算到视图点空间再还原）：
    /// - 矩形类（方框/圆形/打码/聚光/编号）→ 正方形 / 正圆
    /// - 直线 / 箭头 → 吸附到水平 / 垂直 / 45°
    private func shiftConstrainedPoint(_ n: CGPoint, for tool: AnnotationTool) -> CGPoint {
        guard let start = dragStart else { return n }
        let r = imageDrawRect
        guard r.width > 1, r.height > 1 else { return n }
        let dxView = (n.x - start.x) * r.width
        let dyView = (n.y - start.y) * r.height

        switch tool {
        case .rectangle, .filledRectangle, .ellipse, .blur, .pixelate, .spotlight, .numberedCircle:
            let side = max(abs(dxView), abs(dyView))
            let dx = (dxView >= 0 ? side : -side) / r.width
            let dy = (dyView >= 0 ? side : -side) / r.height
            return CGPoint(x: start.x + dx, y: start.y + dy)
        case .line, .arrow:
            let length = hypot(dxView, dyView)
            guard length > 0.5 else { return n }
            let angle = atan2(dyView, dxView)
            let snapped = (angle / (CGFloat.pi / 4)).rounded() * (CGFloat.pi / 4)
            return CGPoint(
                x: start.x + cos(snapped) * length / r.width,
                y: start.y + sin(snapped) * length / r.height
            )
        default:
            return n
        }
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
        // 选区调整后：基图换成裁剪结果，标注重映射到新选区（复制/贴图同款）
        let base = croppedImage() ?? image
        return BeautifierRenderer.render(image: base, config: config, annotations: remappedAnnotations())
    }

    /// 复制到剪贴板（含标注）。
    func copyImageToPasteboard() {
        guard let cg = renderedImage() else { return }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
    }

    /// 供工具栏「复制」按钮拖出：把成品包成拖拽项。
    /// 拖动 = 直接拖进别的应用，单击 = 仅复制到剪贴板，两者互不干扰。
    func dragItemProvider() -> NSItemProvider {
        guard let rendered = renderedImage() else { return NSItemProvider() }
        return ImageDragSource.itemProvider(
            for: rendered,
            suggestedName: Self.dragOutSuggestedName()
        )
    }

    /// ⌥ 拖动：把成品从选区里"抠"出来，交给系统拖拽会话。
    private func beginImageDragOut(with event: NSEvent) {
        guard let rendered = renderedImage() else { return }
        let item = NSDraggingItem(
            pasteboardWriter: ImageDragSource.pasteboardItem(
                for: rendered,
                suggestedName: Self.dragOutSuggestedName()
            )
        )

        // 拖拽预览按屏幕上的实际显示尺寸缩到 160pt 以内：
        // 5K 长图原尺寸跟手会把整个屏幕糊住。
        let drawn = imageDrawRect.size
        let scale = min(160 / max(drawn.width, 1), 160 / max(drawn.height, 1), 1)
        let previewSize = CGSize(
            width: max(drawn.width * scale, 1),
            height: max(drawn.height * scale, 1)
        )
        item.setDraggingFrame(
            CGRect(
                x: imageDrawRect.midX - previewSize.width / 2,
                y: imageDrawRect.midY - previewSize.height / 2,
                width: previewSize.width,
                height: previewSize.height
            ),
            contents: NSImage(
                cgImage: rendered,
                size: NSSize(width: rendered.width, height: rendered.height)
            )
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// 拖出文件的建议名，跟随用户的「文件命名」偏好。
    private static func dragOutSuggestedName() -> String {
        (AppPreferences.generateFileName(ext: "png") as NSString).deletingPathExtension
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

// MARK: - 拖出到其他应用

extension ConfirmCanvasView: NSDraggingSource {
    /// 拖出去永远是"复制一份给别人"，不移动、不删除原图。
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }
}
