import AppKit
import SwiftUI

/// 截图后的“冻结工具台”。所有功能直接可见，不用猜省略号里藏了什么。
/// 图标统一为轻量线性 SF Symbols；文字常驻，hover 再补充一句具体用法。
struct ConfirmToolbarView: View {
    let controller: CaptureConfirmController

    // 飞书同款“记住上次设置”（draw_color / 画笔粗细）：上次选过什么，
    // 这次截图默认就是什么，不用每张图都重选。
    @State private var activeTool: AnnotationTool = .select
    @State private var swatch: AnnotationSwatch
    @State private var widthRaw: Int
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var ocrActive = false
    @State private var contentAnalysisState: CaptureContentAnalysisState = .analyzing
    @State private var showsQRPanel = false
    @State private var plateTool: AnnotationTool = .select

    init(controller: CaptureConfirmController) {
        self.controller = controller
        _swatch = State(initialValue: Self.storedSwatch)
        _widthRaw = State(initialValue: Self.storedWidthIndex)
    }

    private static var storedSwatch: AnnotationSwatch {
        let id = UserDefaults.standard.string(forKey: Self.swatchKey)
        return AnnotationSwatch.allCases.first { $0.id == id } ?? .mustard
    }

    private static var storedWidthIndex: Int {
        let index = UserDefaults.standard.integer(forKey: Self.widthKey)
        return (0...2).contains(index) ? index : 1
    }

    private static let swatchKey = "bs_annotation_swatch_id"
    private static let widthKey = "bs_annotation_width_index"

    @Namespace private var toolSelectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canvas: ConfirmCanvasView? { controller.canvas }
    private let swatches: [AnnotationSwatch] = [.mustard, .coral, .teal, .indigo, .black, .white]
    private let widths: [CGFloat] = [2, 4, 8]

    private var showsColorOptions: Bool {
        [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .text, .numberedCircle, .highlight, .watermark].contains(activeTool)
    }

    private var showsWidthOptions: Bool {
        [.rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .numberedCircle].contains(activeTool)
    }

    var body: some View {
        HStack(spacing: 4) {
            // 拖动把手（飞书同款）：工具条最左边这一小片可以拖着走。
            // 整屏截图时工具条自动只能落在屏幕左下角、正压着画面，挪不动很碍事。
            FreezeToolbarGrip()

            annotationTools

            if showsColorOptions || showsWidthOptions {
                FreezeSeparator()
                annotationProperties
            }

            FreezeSeparator()

            FreezeToolButton(
                title: "撤销",
                help: "撤销上一步标注（⌘Z）",
                icon: "arrow.uturn.backward",
                isEnabled: canUndo
            ) {
                canvas?.finishTextEditing()
                canvas?.undo()
                canUndo = canvas?.canUndo ?? false
                canRedo = canvas?.canRedo ?? false
            }

            FreezeToolButton(
                title: "重做",
                help: "重做被撤销的标注（Z）",
                icon: "arrow.uturn.forward",
                isEnabled: canRedo
            ) {
                canvas?.finishTextEditing()
                canvas?.redo()
                canUndo = canvas?.canUndo ?? false
                canRedo = canvas?.canRedo ?? false
            }

            FreezeSeparator()

            captureContentMenu

            // 提取文字 / 翻译：飞书工具条上这是一级图标，
            // 之前埋在「截图内容」菜单里，等于藏了一层。
            FreezeToolButton(
                title: "提取文字",
                help: detectedText == nil
                    ? "这张截图里没识别到文字"
                    : "在截图上框选要提取的文字（OCR）",
                icon: "selection.pin.in.out",
                isActive: ocrActive,
                isEnabled: detectedText != nil,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) {
                canvas?.finishTextEditing()
                toggleTextSelection()
            }

            FreezeToolButton(
                title: "翻译",
                help: detectedText == nil
                    ? "这张截图里没识别到文字，没法翻译"
                    : "把识别到的文字交给系统翻译",
                icon: "character.book.closed",
                isEnabled: detectedText != nil && TranslationPanelController.shared.isAvailable,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) {
                canvas?.finishTextEditing()
                guard let text = detectedText else { return }
                TranslationPanelController.shared.show(text: text)
            }

            FreezeToolButton(
                title: "长图",
                help: "沿用当前选区开始滚动截图",
                icon: "arrow.down.to.line.compact"
            ) {
                canvas?.finishTextEditing()
                controller.requestScrollCapture()
            }

            FreezeToolButton(
                title: "连拍",
                help: "沿用当前选区开始连续截图",
                icon: "square.stack.3d.up"
            ) {
                canvas?.finishTextEditing()
                controller.requestBurstCapture()
            }

            FreezeSeparator()

            FreezeToolButton(
                title: "保存",
                help: "保存截图到文件夹（⌘S）",
                icon: "square.and.arrow.down"
            ) {
                controller.confirm()
            }

            FreezeToolButton(
                title: "贴图",
                help: "把截图钉在桌面最上层，方便对照（P）",
                icon: "pin.fill"
            ) {
                canvas?.pinImage()
                controller.cancel()
            }

            FreezeSeparator()

            FreezeEndButton(title: "取消", icon: "xmark", isPrimary: false) {
                controller.cancel()
            }
            .help("放弃这次截图（Esc 或 X）")

            FreezeEndButton(title: "复制", icon: "square.on.square", isPrimary: true) {
                controller.copyOnlyAndConfirm()
            }
            .onDrag {
                canvas?.dragItemProvider() ?? NSItemProvider()
            }
            .help("点击复制到剪贴板；也可以直接拖进别的应用（或在选区内按住 ⌥ 拖动）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(FreezeToolbarBackground())
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { controller.toolbarSizeChanged(geometry.size) }
                    .onChange(of: geometry.size) { _, size in
                        controller.toolbarSizeChanged(size)
                    }
            }
        )
        .fixedSize(horizontal: true, vertical: true)
        .runeTypography()
        .onAppear {
            canUndo = canvas?.canUndo ?? false
            ocrActive = canvas?.ocrMode ?? false
            contentAnalysisState = canvas?.contentAnalysisState ?? .analyzing
            // 恢复上次会话的标注默认值（颜色/粗细），画布与工具栏同步
            canvas?.selectedSwatch = swatch
            canvas?.strokeWidth = widths[widthRaw]
        }
        .onChange(of: swatch) { _, newSwatch in
            UserDefaults.standard.set(newSwatch.id, forKey: Self.swatchKey)
        }
        .onChange(of: widthRaw) { _, newIndex in
            UserDefaults.standard.set(newIndex, forKey: Self.widthKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmCanvasStateDidChange)) { note in
            guard note.object as? ConfirmCanvasView === canvas else { return }
            canUndo = canvas?.canUndo ?? false
            canRedo = canvas?.canRedo ?? false
            ocrActive = canvas?.ocrMode ?? false
            // 键盘快捷键切工具时同步高亮
            if let tool = canvas?.selectedTool, tool != activeTool {
                activeTool = tool
                plateTool = tool
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmCaptureContentDidChange)) { note in
            guard note.object as? ConfirmCanvasView === canvas else { return }
            contentAnalysisState = canvas?.contentAnalysisState ?? .analyzing
        }
    }

    private var captureContentMenu: some View {
        let presentation = contentMenuPresentation
        return Menu {
            captureContentCommands
        } label: {
            FreezeContentLabel(
                title: presentation.title,
                icon: presentation.icon,
                isActive: ocrActive,
                hasResult: presentation.hasResult
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("理解截图内容：复制文字、打开链接或一键打码")
        .accessibilityLabel("截图内容")
        .accessibilityHint("查看截图中识别到的文字、链接、二维码和敏感信息")
    }

    @ViewBuilder
    private var captureContentCommands: some View {
        switch contentAnalysisState {
        case .analyzing:
            Button("正在本地识别…") {}
                .disabled(true)

        case let .ready(analysis):
            if let text = analysis.text {
                let characterCount = text.replacingOccurrences(of: "\n", with: "").count
                Button(
                    "复制全部文字（\(analysis.textBlockCount) 行 · \(characterCount) 字）",
                    systemImage: "doc.on.doc"
                ) {
                    copyString(text, message: "已复制全部文字")
                }
                if TranslationPanelController.shared.isAvailable {
                    Button("翻译截图文字", systemImage: "character.book.closed") {
                        TranslationPanelController.shared.show(text: text)
                    }
                }
                Button(
                    ocrActive ? "退出选字模式" : "选取部分文字",
                    systemImage: "selection.pin.in.out"
                ) {
                    toggleTextSelection()
                }
            }

            if !analysis.links.isEmpty {
                Divider()
                Menu("识别到 \(analysis.links.count) 个链接", systemImage: "link") {
                    ForEach(Array(analysis.links.prefix(5)), id: \.absoluteString) { url in
                        Menu(linkLabel(url)) {
                            Button("打开链接", systemImage: "safari") {
                                NSWorkspace.shared.open(url)
                            }
                            Button("复制链接", systemImage: "doc.on.doc") {
                                copyString(url.absoluteString, message: "链接已复制")
                            }
                        }
                    }
                }
            }

            if !analysis.nonLinkBarcodes.isEmpty {
                Divider()
                Menu("二维码或条码", systemImage: "qrcode.viewfinder") {
                    ForEach(Array(analysis.nonLinkBarcodes.prefix(5)), id: \.self) { value in
                        Button("复制 \(shortValue(value))", systemImage: "doc.on.doc") {
                            copyString(value, message: "二维码或条码内容已复制")
                        }
                    }
                }
            }

            if !analysis.sensitiveMatches.isEmpty {
                Divider()
                Button(
                    "打码 \(analysis.sensitiveMatches.count) 处敏感信息",
                    systemImage: "eye.slash"
                ) {
                    let count = canvas?.redactDetectedSensitiveContent() ?? 0
                    ToastWindow.shared.show(
                        title: count > 0 ? "已自动打码" : "无需重复打码",
                        message: count > 0 ? "已遮住 \(count) 处敏感信息，可用撤销恢复" : "这些位置已经处理过了",
                        systemIcon: "eye.slash"
                    )
                }
            }

            Divider()
            Button("完全在本地处理", systemImage: "lock.fill") {}
                .disabled(true)

        case .empty:
            Button("没有发现可提取内容") {}
                .disabled(true)
            Button("重新识别", systemImage: "arrow.clockwise") {
                canvas?.beginContentAnalysis(force: true)
            }

        case .failed:
            Button("内容识别没有完成") {}
                .disabled(true)
            Button("重新识别", systemImage: "arrow.clockwise") {
                canvas?.beginContentAnalysis(force: true)
            }
        }
    }

    private var contentMenuPresentation: (title: String, icon: String, hasResult: Bool) {
        switch contentAnalysisState {
        case .analyzing:
            return ("理解中", "text.magnifyingglass", false)
        case let .ready(analysis):
            if !analysis.sensitiveMatches.isEmpty {
                return ("敏感 \(analysis.sensitiveMatches.count)", "eye.slash", true)
            }
            if !analysis.links.isEmpty {
                return ("链接 \(analysis.links.count)", "link", true)
            }
            if analysis.textBlockCount > 0 {
                // Vision 按行返回识别结果——标"行"避免被读成"字数"
                return ("文字 \(analysis.textBlockCount) 行", "text.viewfinder", true)
            }
            return ("内容", "doc.viewfinder", true)
        case .empty:
            return ("内容", "doc.viewfinder", false)
        case .failed:
            return ("重试", "arrow.clockwise", false)
        }
    }

    private func toggleTextSelection() {
        ocrActive.toggle()
        canvas?.toggleOCRMode { message in
            if message == "未识别到文字" { ocrActive = false }
            ToastWindow.shared.show(
                title: "文字识别",
                message: message,
                systemIcon: "text.viewfinder"
            )
        }
    }

    private func copyString(_ value: String, message: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        ToastWindow.shared.show(
            title: "已复制",
            message: message,
            systemIcon: "doc.on.doc"
        )
    }

    private func linkLabel(_ url: URL) -> String {
        shortValue(url.host ?? url.absoluteString)
    }

    private func shortValue(_ value: String) -> String {
        let limit = 34
        guard value.count > limit else { return value }
        return "\(value.prefix(limit))…"
    }

    private var isAnalyzingContent: Bool {
        if case .analyzing = contentAnalysisState { return true }
        return false
    }

    /// 这张截图里识别到的文字（没有就 nil）
    private var detectedText: String? {
        guard case let .ready(analysis) = contentAnalysisState else { return nil }
        guard let text = analysis.text, !text.isEmpty else { return nil }
        return text
    }

    /// 画布后台一直在识别条码，这里直接把结果摆出来（飞书同款：工具条一等公民）
    private var qrCodes: [String] {
        guard case let .ready(analysis) = contentAnalysisState else { return [] }
        return analysis.barcodes
    }

    private var qrPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("二维码 / 条码")
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                Spacer()
                if qrCodes.isEmpty {
                    Text(isAnalyzingContent ? "识别中…" : "没有识别到")
                        .font(RuneFont.swiftUI(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if qrCodes.isEmpty {
                Text("这张截图里没有二维码或条码。换一张带码的图再试。")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(qrCodes.prefix(8)), id: \.self) { value in
                    HStack(spacing: 8) {
                        Text(value)
                            .font(RuneFont.mono(size: 10.5))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button {
                            copyString(value, message: "二维码内容已复制")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制")
                        if let url = URL(string: value), url.scheme != nil {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.borderless)
                            .help("打开链接")
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 420)
    }

    /// 标注工具组。分组跟飞书一致：**绘制 | 效果/内容**，
    /// 中间一条分隔线。之前 15 个图标是混着排的（高亮夹在画笔和文字中间、
    /// 编号和标签夹在效果工具中间），要找一个工具得把整排扫过去。
    private var annotationTools: some View {
        HStack(spacing: 1) {
            FreezeToolButton(
                title: "选择",
                help: "选择并移动已经画好的标注，Delete 可以删除（V）",
                icon: "cursorarrow.rays",
                isActive: activeTool == .select,
                showsSelectionPlate: plateTool == .select,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.select) }

            FreezeSeparator()

            // ── 绘制
            FreezeToolButton(
                title: "方框",
                help: "拖拽画出一个醒目的矩形框；Shift = 正方形（R）",
                icon: "rectangle.dashed",
                isActive: activeTool == .rectangle,
                showsSelectionPlate: plateTool == .rectangle,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.rectangle) }

            FreezeToolButton(
                title: "圆形",
                help: "拖拽画椭圆，按住 Shift 可画正圆（O）",
                icon: "circle",
                isActive: activeTool == .ellipse,
                showsSelectionPlate: plateTool == .ellipse,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.ellipse) }

            FreezeToolButton(
                title: "直线",
                help: "拖拽画一条直线；Shift = 水平/垂直/45°（L）",
                icon: "line.diagonal",
                isActive: activeTool == .line,
                showsSelectionPlate: plateTool == .line,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.line) }

            FreezeToolButton(
                title: "箭头",
                help: "拖拽画一支指向重点的箭头；Shift = 水平/垂直/45°（A）",
                icon: "arrow.up.right",
                isActive: activeTool == .arrow,
                showsSelectionPlate: plateTool == .arrow,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.arrow) }

            FreezeToolButton(
                title: "画笔",
                help: "自由手绘勾画（D）",
                icon: "scribble",
                isActive: activeTool == .freehand,
                showsSelectionPlate: plateTool == .freehand,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.freehand) }

            FreezeToolButton(
                title: "文字",
                help: "点击截图任意位置输入说明文字（T）",
                icon: "character.cursor.ibeam",
                isActive: activeTool == .text,
                showsSelectionPlate: plateTool == .text,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.text) }

            FreezeToolButton(
                title: "编号",
                help: "依次放置 1、2、3…编号圆点（N）",
                icon: "number.circle",
                isActive: activeTool == .numberedCircle,
                showsSelectionPlate: plateTool == .numberedCircle,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.numberedCircle) }

            FreezeToolButton(
                title: "标签",
                help: "点击落一个指向性气泡，可写说明文字（I）",
                icon: "tag.fill",
                isActive: activeTool == .tag,
                showsSelectionPlate: plateTool == .tag,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.tag) }

            FreezeSeparator()

            // ── 效果 / 内容
            FreezeToolButton(
                title: "高亮",
                help: "拖拽铺一层荧光色，底下文字仍可读（H）",
                icon: "highlighter",
                isActive: activeTool == .highlight,
                showsSelectionPlate: plateTool == .highlight,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.highlight) }

            FreezeToolButton(
                title: "打码",
                help: "拖拽框住需要隐藏的隐私内容（M）",
                icon: "square.grid.3x3.fill",
                isActive: activeTool == .blur,
                showsSelectionPlate: plateTool == .blur,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.blur) }

            FreezeToolButton(
                title: "像素化",
                help: "拖拽把区域打成马赛克（E）",
                icon: "app.background.dotted",
                isActive: activeTool == .pixelate,
                showsSelectionPlate: plateTool == .pixelate,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.pixelate) }

            FreezeToolButton(
                title: "聚光",
                help: "保留重点区域，其余画面自动压暗（G）",
                icon: "viewfinder.circle",
                isActive: activeTool == .spotlight,
                showsSelectionPlate: plateTool == .spotlight,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.spotlight) }

            FreezeToolButton(
                title: "水印",
                help: "点击铺一层斜排文字水印，双击水印可修改文字（W）",
                icon: "seal",
                isActive: activeTool == .watermark,
                showsSelectionPlate: plateTool == .watermark,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.watermark) }

            FreezeToolButton(
                title: "识别二维码",
                help: "识别这张截图里的二维码与条码，可复制或直接打开链接",
                icon: "qrcode.viewfinder",
                isActive: showsQRPanel,
                showsSelectionPlate: false,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { showsQRPanel = true }
            .popover(isPresented: $showsQRPanel, arrowEdge: .bottom) { qrPanel }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                        .strokeBorder(RuneTheme.chromeLine.opacity(0.7), lineWidth: 0.5)
                )
        )
    }

    private var annotationProperties: some View {
        HStack(spacing: 8) {
            if showsColorOptions {
                HStack(spacing: 4) {
                    ForEach(swatches, id: \.self) { color in
                        FreezeSwatch(
                            swatch: color,
                            isSelected: swatch == color
                        ) {
                            swatch = color
                            canvas?.selectedSwatch = color
                            canvas?.updateSelectedAnnotation(swatch: color)
                        }
                    }
                }
            }

            if showsColorOptions && showsWidthOptions {
                Rectangle()
                    .fill(RuneTheme.chromeText.opacity(0.10))
                    .frame(width: 1, height: 22)
            }

            if showsWidthOptions {
                HStack(spacing: 2) {
                    ForEach(widths.indices, id: \.self) { index in
                        Button {
                            widthRaw = index
                            canvas?.strokeWidth = widths[index]
                            canvas?.updateSelectedAnnotation(strokeWidth: widths[index])
                        } label: {
                            Capsule()
                                .fill(widthRaw == index ? RuneTheme.chromeText : RuneTheme.chromeText.opacity(0.50))
                                .frame(width: 15, height: max(2, CGFloat(index + 1) * 2))
                                .frame(width: 28, height: 34)
                                .background(
                                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                                        .fill(widthRaw == index ? RuneTheme.chromeText.opacity(0.11) : .clear)
                                )
                        }
                        .buttonStyle(FreezePressStyle())
                        .help("线条粗细：\(["细", "中", "粗"][index])")
                        .accessibilityLabel("线条粗细：\(["细", "中", "粗"][index])")
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(RuneTheme.chromeElevated.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                        .strokeBorder(RuneTheme.chromeLine, lineWidth: 1)
                )
        )
    }

    private func activate(_ tool: AnnotationTool) {
        canvas?.finishTextEditing()
        activeTool = tool
        if reduceMotion {
            plateTool = tool
        } else {
            withAnimation(RuneSelectionMotion.animation) {
                plateTool = tool
            }
        }
        if ocrActive {
            ocrActive = false
            canvas?.exitOCRMode()
        }
        canvas?.selectedTool = tool
        canvas?.selectedID = nil
        canvas?.needsDisplay = true
        canvas?.refreshCursor()

        #if DEBUG
        if tool == .text,
           ProcessInfo.processInfo.arguments.contains("--audit-confirm-text") {
            canvas?.beginTextInputForAudit()
        }
        #endif
    }
}

private struct FreezeToolbarBackground: View {
    var body: some View {
        RuneGlassBackground(cornerRadius: RuneTheme.barCorner, elevation: .floating)
    }
}

/// 截图确认台里唯一会随内容改变的入口：结果比功能名更重要。
private struct FreezeContentLabel: View {
    let title: String
    let icon: String
    let isActive: Bool
    let hasResult: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(RuneFont.swiftUI(size: 16, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .frame(height: 19)

            Text(title)
                .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                .lineLimit(1)
                .monospacedDigit()
        }
        .foregroundStyle(isActive || hasResult ? RuneTheme.primaryOnFill : RuneTheme.chromeText.opacity(0.80))
        .frame(width: 58, height: 46)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(isActive || hasResult ? RuneTheme.primaryFill : .clear)
                .shadow(color: .black.opacity(isActive || hasResult ? 0.16 : 0), radius: 8, y: 3)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "chevron.down")
                .font(RuneFont.swiftUI(size: 6.5, weight: .bold))
                .foregroundStyle(RuneTheme.chromeText.opacity(0.46))
                .padding(5)
        }
        .contentShape(RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous))
    }
}

private struct FreezeToolButton: View {
    let title: String
    let help: String
    let icon: String
    var isActive = false
    var isEnabled = true
    var showsSelectionPlate = false
    var isCompact = false
    var tint: Color? = nil
    var selectionNamespace: Namespace.ID? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: isCompact ? 0 : 3) {
                Image(systemName: icon)
                    .font(RuneFont.swiftUI(size: 16, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .frame(height: 19)

                if !isCompact {
                    Text(title)
                        .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .frame(width: isCompact ? 36 : 44, height: isCompact ? 38 : 46)
            .background { buttonBackground }
            .overlay(
                RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                    .strokeBorder(border, lineWidth: isActive ? 0.8 : 0.5)
            )
            .shadow(color: isActive ? .black.opacity(0.16) : .clear, radius: 8, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous))
        }
        .buttonStyle(FreezePressStyle())
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help("\(title)：\(help)")
        .accessibilityLabel(title)
        .accessibilityHint(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var buttonBackground: some View {
        if showsSelectionPlate, let selectionNamespace {
            RuneLiquidSelectionPlate(cornerRadius: RuneTheme.buttonCorner)
                .matchedGeometryEffect(
                    id: "confirm-tool-selection",
                    in: selectionNamespace
                )
        } else {
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(background)
        }
    }

    private var foreground: Color {
        if !isEnabled { return RuneTheme.chromeText.opacity(0.24) }
        if isActive { return tint ?? RuneTheme.primaryOnFill }
        if let tint { return tint.opacity(isHovered ? 1 : 0.88) }
        return RuneTheme.chromeText.opacity(isHovered ? 1 : 0.80)
    }

    private var background: Color {
        if !isEnabled { return RuneTheme.chromeText.opacity(0.018) }
        if selectionNamespace != nil { return isHovered ? Color.white.opacity(0.16) : .clear }
        if isActive { return tint?.opacity(0.16) ?? RuneTheme.primaryFill }
        return isHovered ? Color.white.opacity(0.16) : .clear
    }

    private var border: Color {
        if !isEnabled { return RuneTheme.chromeLine.opacity(0.4) }
        if isActive { return .clear }
        return isHovered ? Color.white.opacity(0.28) : .clear
    }
}

private struct FreezeEndButton: View {
    let title: String
    let icon: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(RuneFont.swiftUI(size: 11, weight: .bold))
                Text(title)
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
            }
            .foregroundStyle(isPrimary ? RuneTheme.primaryOnFill : RuneTheme.chromeText.opacity(isHovered ? 1 : 0.82))
            .padding(.horizontal, isPrimary ? 14 : 10)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                    .fill(
                        isPrimary
                            ? RuneTheme.primaryFill
                            : RuneTheme.chromeText.opacity(isHovered ? 0.12 : 0.065)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                    .strokeBorder(
                        isPrimary ? Color.white.opacity(0.6) : RuneTheme.chromeLine,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPrimary ? .black.opacity(isHovered ? 0.26 : 0.18) : .clear,
                radius: isHovered ? 12 : 8,
                y: 4
            )
        }
        .buttonStyle(FreezePressStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

private struct FreezeSwatch: View {
    let swatch: AnnotationSwatch
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(swatch.nsColor))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(RuneTheme.chromeText.opacity(0.72), lineWidth: 0.7))
                .padding(4)
                .background(
                    Circle()
                        .fill(isHovered ? RuneTheme.chromeText.opacity(0.12) : .clear)
                )
                .overlay(
                    Circle()
                        .strokeBorder(isSelected ? RuneTheme.chromeText.opacity(0.90) : .clear, lineWidth: 1.2)
                )
        }
        .buttonStyle(FreezePressStyle())
        .onHover { isHovered = $0 }
        .help("标注颜色：\(swatch.title)")
        .accessibilityLabel("标注颜色：\(swatch.title)")
    }
}

/// 工具条拖动把手：六点抓手（飞书同款）。
private struct FreezeToolbarGrip: View {
    var body: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    ForEach(0..<2, id: \.self) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.34))
                            .frame(width: 2.4, height: 2.4)
                    }
                }
            }
        }
        .frame(width: CaptureConfirmController.toolbarGripWidth, height: 38)
        .contentShape(Rectangle())
        .help("拖动工具条")
        .accessibilityLabel("拖动工具条")
    }
}

private struct FreezeSeparator: View {
    var body: some View {
        Rectangle()
            .fill(RuneTheme.chromeText.opacity(0.10))
            .frame(width: 1, height: 30)
            .padding(.horizontal, 4)
    }
}

private struct FreezePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
