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

    // 选字模式（钉钉/飞书式）：识别出的文字块可点选/划选复制
    var ocrMode = false
    private(set) var ocrBlocks: [(text: String, frame: CGRect)] = []   // frame=视图坐标
    private var ocrDragStart: CGPoint?
    private var ocrDragRect: CGRect?

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
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1. 画截图（铺满本屏区域；图按屏绘制，非拉伸）
        ctx.saveGState()
        ctx.interpolationQuality = .medium
        // 图像物理像素 → 本屏点尺寸（用 bounds：副屏 frame 是全局坐标会画到屏外）
        let drawRect = imageDrawRect
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()

        // 1.5 选字模式：文字块高亮（必须在"无标注提前 return"之前，
        // 否则刚截完图（0 标注）时蓝块永远画不出来）
        if ocrMode {
            let selRect = ocrDragRect
            for block in ocrBlocks {
                let selected = selRect.map { !$0.intersection(block.frame).isNull } ?? false
                NSColor.systemBlue.withAlphaComponent(selected ? 0.42 : 0.16).setFill()
                block.frame.insetBy(dx: -2, dy: -1).fill()
            }
            if let selRect {
                NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
                let path = NSBezierPath(rect: selRect)
                path.lineWidth = 1
                path.stroke()
            }
        }

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

        // 3. 选中高亮：红色圆角虚线框 + 四角白色手柄方块（视觉上"可操作"）
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
    private var imageDrawRect: CGRect {
        let scale = screen.backingScaleFactor
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return CGRect(
            x: bounds.midX - pointSize.width / 2,
            y: bounds.midY - pointSize.height / 2,
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
    /// 注意：AppKit 视图坐标原点在左下角（Y 向上），模型要 Y-down（顶部=0），
    /// 所以 Y 必须用 maxY 反着算，否则标注上下镜像（往下拉却往上画）。
    private func normalizedPoint(_ p: CGPoint) -> CGPoint {
        let r = imageDrawRect
        return CGPoint(
            x: (p.x - r.minX) / r.width,
            y: (r.maxY - p.y) / r.height
        )
    }

    // MARK: - 鼠标交互

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        // 选字模式：开始划选
        if ocrMode {
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

        // 文字：点击放置 + 就地输入（回车确认；留空=不放置）
        if selectedTool == .text {
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
            beginTextEditing(item: item, at: loc)
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
        case 53:   // Esc → 选字模式优先退出选字；否则取消（零残留）
            if ocrMode { exitOCRMode() } else { controller?.cancel() }
        case 36, 76:  // Enter / 小回车 → 保存
            controller?.confirm()
        case 51:   // Delete → 删除选中
            deleteSelected()
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 文字就地输入

    private var editingTextField: NSTextField?
    private var editingItemID: AnnotationItem.ID?

    /// 在点击位置弹一个输入框，回车/点别处确认；留空则放弃放置。
    private func beginTextEditing(item: AnnotationItem, at viewPoint: CGPoint) {
        endTextEditing(commit: true)
        let tf = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y - 14, width: 180, height: 28))
        tf.font = .systemFont(ofSize: 15)
        tf.placeholderString = "输入文字，回车确认"
        tf.focusRingType = .none
        tf.bezelStyle = .roundedBezel
        tf.backgroundColor = .white
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textFieldCommit(_:))
        addSubview(tf)
        editingTextField = tf
        editingItemID = item.id
        window?.makeFirstResponder(tf)
    }

    @objc private func textFieldCommit(_ sender: NSTextField) {
        endTextEditing(commit: true)
    }

    private func endTextEditing(commit: Bool) {
        guard let tf = editingTextField else { return }
        let id = editingItemID
        editingTextField = nil
        editingItemID = nil

        if commit, let id,
           let idx = annotations.firstIndex(where: { $0.id == id }) {
            let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                annotations.remove(at: idx)
                if selectedID == id { selectedID = nil }
            } else {
                annotations[idx].text = text
                selectedID = id
            }
        }
        tf.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
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

    /// 「识别文字」→ 选字模式：识别出带位置的文字块，点选/划选复制（钉钉式）。
    /// 再次调用或 Esc 退出选字，回到标注模式。
    func toggleOCRMode(onDone: @escaping (String) -> Void) {
        if ocrMode {
            exitOCRMode()
            return
        }
        let cg = image   // 用原始截图：boundingBox 相对原图，才能对上 imageDrawRect 的映射
        Task { @MainActor in
            guard let observations = try? await OCRService.shared.recognizeWithPositions(in: cg),
                  !observations.isEmpty else {
                onDone("未识别到文字")
                return
            }
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
            refreshCursor()
            needsDisplay = true
            onDone("选字模式：点一块复制一块，拖动选一段；Esc 退出")
        }
    }

    func exitOCRMode() {
        ocrMode = false
        ocrBlocks = []
        ocrDragStart = nil
        ocrDragRect = nil
        refreshCursor()
        needsDisplay = true
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
        onDone?("已复制 \(sorted.count) 块文字")
    }

    /// 渲染"截图+标注"成品（复用 BeautifierRenderer 的标注烘焙）。
    /// 用用户设置的美化配置（与保存链一致——此前写死默认值，贴图/复制会和保存效果不一致）。
    func renderedImage() -> CGImage? {
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

// MARK: - 文字输入框代理：点别处/回车/按 Esc 都走提交路径（留空=放弃）
extension ConfirmCanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endTextEditing(commit: true)
    }
}
