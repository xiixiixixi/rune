import AppKit
import SwiftUI

/// 截图后的“冻结工具台”。所有功能直接可见，不用猜省略号里藏了什么。
/// 图标统一为轻量线性 SF Symbols；文字常驻，hover 再补充一句具体用法。
struct ConfirmToolbarView: View {
    let controller: CaptureConfirmController

    @State private var activeTool: AnnotationTool = .select
    @State private var swatch: AnnotationSwatch = .mustard
    @State private var widthRaw = 1
    @State private var customColor = Color(red: 0.85, green: 0.64, blue: 0.25)
    @State private var canUndo = false
    @State private var ocrActive = false
    @State private var contentAnalysisState: CaptureContentAnalysisState = .analyzing
    @State private var plateTool: AnnotationTool = .select

    @Namespace private var toolSelectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canvas: ConfirmCanvasView? { controller.canvas }
    private let swatches: [AnnotationSwatch] = [.mustard, .coral, .teal, .indigo, .black, .white]
    private let widths: [CGFloat] = [2, 4, 8]

    private var showsColorOptions: Bool {
        [.rectangle, .arrow, .text, .numberedCircle].contains(activeTool)
    }

    private var showsWidthOptions: Bool {
        [.rectangle, .arrow, .numberedCircle].contains(activeTool)
    }

    var body: some View {
        HStack(spacing: 4) {
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
            }

            FreezeSeparator()

            captureContentMenu

            FreezeToolButton(
                title: "长图",
                help: "沿用当前选区开始滚动截图",
                icon: "arrow.down.to.line.compact"
            ) {
                controller.requestScrollCapture()
            }

            FreezeToolButton(
                title: "连拍",
                help: "沿用当前选区，连续、定数或延时拍摄",
                icon: "square.stack.3d.up.fill"
            ) {
                controller.requestBurstCapture()
            }

            FreezeSeparator()

            FreezeToolButton(
                title: "保存",
                help: "保存截图到文件夹",
                icon: "square.and.arrow.down"
            ) {
                controller.confirm()
            }

            FreezeToolButton(
                title: "贴图",
                help: "把截图钉在桌面最上层，方便对照",
                icon: "pin.fill"
            ) {
                canvas?.pinImage()
                controller.cancel()
            }

            FreezeSeparator()

            FreezeEndButton(title: "取消", icon: "xmark", isPrimary: false) {
                controller.cancel()
            }
            .help("放弃这次截图（Esc）")

            FreezeEndButton(title: "复制", icon: "square.on.square", isPrimary: true) {
                controller.copyAndConfirm()
            }
            .help("复制到剪贴板并保存（Enter）")
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .confirmCanvasStateDidChange)) { note in
            guard note.object as? ConfirmCanvasView === canvas else { return }
            canUndo = canvas?.canUndo ?? false
            ocrActive = canvas?.ocrMode ?? false
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
                Button("复制全部文字", systemImage: "doc.on.doc") {
                    copyString(text, message: "已复制全部文字")
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
                return ("文字 \(analysis.textBlockCount)", "text.viewfinder", true)
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

    private var annotationTools: some View {
        HStack(spacing: 1) {
            FreezeToolButton(
                title: "选择",
                help: "选择并移动已经画好的标注，Delete 可以删除",
                icon: "cursorarrow.rays",
                isActive: activeTool == .select,
                showsSelectionPlate: plateTool == .select,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.select) }

            FreezeToolButton(
                title: "方框",
                help: "拖拽画出一个醒目的矩形框",
                icon: "rectangle.dashed",
                isActive: activeTool == .rectangle,
                showsSelectionPlate: plateTool == .rectangle,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.rectangle) }

            FreezeToolButton(
                title: "箭头",
                help: "拖拽画一支指向重点的箭头",
                icon: "arrow.up.right",
                isActive: activeTool == .arrow,
                showsSelectionPlate: plateTool == .arrow,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.arrow) }

            FreezeToolButton(
                title: "文字",
                help: "点击截图任意位置输入说明文字",
                icon: "character.cursor.ibeam",
                isActive: activeTool == .text,
                showsSelectionPlate: plateTool == .text,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.text) }

            FreezeToolButton(
                title: "打码",
                help: "拖拽框住需要隐藏的隐私内容",
                icon: "square.grid.3x3.fill",
                isActive: activeTool == .blur,
                showsSelectionPlate: plateTool == .blur,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.blur) }

            FreezeToolButton(
                title: "聚光",
                help: "保留重点区域，其余画面自动压暗",
                icon: "viewfinder.circle",
                isActive: activeTool == .spotlight,
                showsSelectionPlate: plateTool == .spotlight,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.spotlight) }

            FreezeToolButton(
                title: "编号",
                help: "依次放置 1、2、3…编号圆点",
                icon: "number.circle",
                isActive: activeTool == .numberedCircle,
                showsSelectionPlate: plateTool == .numberedCircle,
                isCompact: true,
                selectionNamespace: toolSelectionNamespace
            ) { activate(.numberedCircle) }
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

                    ColorPicker("自定义颜色", selection: $customColor, supportsOpacity: false)
                        .labelsHidden()
                        .scaleEffect(0.68)
                        .frame(width: 24, height: 32)
                        .help("自定义标注颜色")
                        .onChange(of: customColor) { _, newColor in
                            let custom = AnnotationSwatch.custom(from: newColor)
                            swatch = custom
                            canvas?.selectedSwatch = custom
                            canvas?.updateSelectedAnnotation(swatch: custom)
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
