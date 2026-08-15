import AppKit

/// 确认模式画布：显示截图 + 就地标注（拖画/选中/移动/删除）。
///
/// 复用 AnnotationItem 模型（0-1 归一化、Y-down）与 AnnotationDrawing 烘焙渲染。
/// 键盘：Esc=取消（不保存）、Enter/⌘S=保存、⌘Z=撤销、Delete=删除选中。
final class ConfirmCanvasView: NSView {
    private let image: CGImage
    private let screen: NSScreen
    private weak var controller: CaptureConfirmController?

    // MARK: - 标注状态（工具栏读写；确认时由控制器读走烘焙）

    var annotations: [AnnotationItem] = []
    private var undoStack: [[AnnotationItem]] = []

    var selectedTool: AnnotationTool = .select
    var selectedSwatch: AnnotationSwatch = .red
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

    init(image: CGImage, screen: NSScreen, controller: CaptureConfirmController) {
        self.image = image
        self.screen = screen
        self.controller = controller
        super.init(frame: screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - 工具栏入口（撤销 / 删除选中）

    func undo() {
        guard !undoStack.isEmpty else { return }
        annotations = undoStack.removeLast()
        selectedID = nil
        needsDisplay = true
    }

    var canUndo: Bool { !undoStack.isEmpty }

    func deleteSelected() {
        guard let id = selectedID else { return }
        pushUndo()
        annotations.removeAll { $0.id == id }
        selectedID = nil
        needsDisplay = true
    }

    private func pushUndo() {
        undoStack.append(annotations)
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 画截图（铺满本屏区域；图按屏绘制，非拉伸）
        ctx.saveGState()
        ctx.interpolationQuality = .medium
        // 图像物理像素 → 本屏点尺寸
        let scale = screen.backingScaleFactor
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let drawRect = CGRect(
            x: frame.midX - pointSize.width / 2,
            y: frame.midY - pointSize.height / 2,
            width: pointSize.width,
            height: pointSize.height
        )
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()

        // 2. 画标注（归一化坐标映射到 drawRect；Y-down → CG 用 flipped 渲染）
        var items = annotations
        if let draft { items.append(draft) }
        guard !items.isEmpty else { return }

        ctx.saveGState()
        // AnnotationDrawing.draw(flipped:true) 要求上下文为 Y-down：整体翻转一次
        ctx.translateBy(x: 0, y: drawRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let flippedRect = CGRect(x: drawRect.minX, y: 0, width: drawRect.width, height: drawRect.height)
        AnnotationDrawing.draw(
            items,
            in: ctx,
            imageRect: flippedRect,
            fullCanvasRect: flippedRect,
            sourceImage: image,
            flipped: true
        )
        ctx.restoreGState()

        // 3. 选中高亮（红色细框）
        if let id = selectedID,
           let item = annotations.first(where: { $0.id == id }) {
            let r = viewRect(for: item.bounds)
            ctx.strokePath()
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
            ctx.stroke(r.insetBy(dx: -3, dy: -3))
        }
    }

    /// 归一化 rect → 视图 rect。
    private var imageDrawRect: CGRect {
        let scale = screen.backingScaleFactor
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return CGRect(
            x: frame.midX - pointSize.width / 2,
            y: frame.midY - pointSize.height / 2,
            width: pointSize.width,
            height: pointSize.height
        )
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
    private func normalizedPoint(_ p: CGPoint) -> CGPoint {
        let r = imageDrawRect
        return CGPoint(
            x: (p.x - r.minX) / r.width,
            y: (p.y - r.minY) / r.height    // Y-down 语义：视图顶部 = 0
        )
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
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

        // 文字：点击放置
        if selectedTool == .text {
            pushUndo()
            let item = AnnotationItem(
                tool: .text,
                rect: CGRect(x: n.x, y: n.y, width: 0.3, height: 0.06),
                points: [],
                swatch: selectedSwatch,
                strokeWidth: strokeWidth,
                text: "双击输入文字"
            )
            annotations.append(item)
            selectedID = item.id
            needsDisplay = true
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
        case 53:   // Esc → 取消（零残留）
            controller?.cancel()
        case 36, 76:  // Enter / 小回车 → 保存
            controller?.confirm()
        case 51:   // Delete → 删除选中
            deleteSelected()
        default:
            super.keyDown(with: event)
        }
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
        case .rectangle, .blur:
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

    /// 渲染"截图+标注"成品（复用 BeautifierRenderer 的标注烘焙）。
    func renderedImage() -> CGImage? {
        let config = BeautifierConfig.default
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
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // PinnedScreenshotController.pin 吃 URL；写临时文件喂它
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("轻截_贴图_\(Int(Date().timeIntervalSince1970 * 1000)).png")
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
