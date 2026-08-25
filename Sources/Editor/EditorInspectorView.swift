import SwiftUI
import UniformTypeIdentifiers

struct EditorInspectorView: View {
    @Bindable var model: EditorModel
    @State private var panel: InspectorPanel = .annotation

    var body: some View {
        VStack(spacing: 0) {
            Picker("编辑面板", selection: $panel) {
                ForEach(InspectorPanel.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if panel == .annotation {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.inspectedTool?.title ?? "选择")
                            .font(RuneFont.swiftUI(size: 24, weight: .bold))
                            .foregroundStyle(RuneTheme.paperInk)

                        Text(
                            model.selectionCount > 0
                                ? "正在调整已选标注"
                                : "工具在画布下方，属性会随选择更新。"
                        )
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(RuneTheme.paperTextMuted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 14)

                    if !model.items.isEmpty {
                        Button(role: .destructive) {
                            model.clearAnnotations()
                        } label: {
                            Label("全部清除", systemImage: "trash")
                                .font(RuneFont.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }

                    if model.inspectedTool != nil {
                        // MARK: Style
                        VStack(alignment: .leading, spacing: 10) {
                            InspectorSectionHeader("属性")

                            if model.selectionCount > 1 {
                                Text("已选择 \(model.selectionCount) 个标注")
                                    .font(RuneFont.caption)
                                    .foregroundStyle(RuneTheme.paperTextSecondary)
                            }

                            InspectorRow(title: "颜色") {
                                AnnotationColorMenu(selectedSwatch: model.selectedSwatch) { swatch in
                                    model.setSwatch(swatch)
                                }
                            }

                            if model.isStrokeStyleAvailable {
                                InspectorRow(title: "线条") {
                                    AnnotationStrokeMenu(strokeWidth: model.strokeWidth) { strokeWidth in
                                        model.setStrokeWidth(strokeWidth)
                                    }
                                }
                            }

                            if model.isRedactionStyleAvailable {
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("密度")
                                            .font(RuneFont.caption2)
                                            .foregroundStyle(RuneTheme.paperTextMuted)
                                        Spacer()
                                        Text("\(Int(model.redactionDensity * 100))%")
                                            .font(RuneFont.caption2)
                                            .foregroundStyle(RuneTheme.paperTextMuted)
                                    }
                                    Slider(
                                        value: Binding(
                                            get: { model.redactionDensity },
                                            set: { model.setRedactionDensity($0) }
                                        ),
                                        in: 0.15...1
                                    )
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    if model.isTextStyleAvailable {
                        InspectorDivider()

                        // MARK: Text
                        VStack(alignment: .leading, spacing: 10) {
                            InspectorSectionHeader("文字")
                            AnnotationTextStyleControls(model: model)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                    } else {
                    // MARK: Beautify
                    VStack(alignment: .leading, spacing: 6) {
                        InspectorSectionHeader("美化")
                        Text("把截图包装成适合分享的卡片：裁剪画面、加边距圆角阴影、配纯色或渐变背景。")
                            .font(RuneFont.caption2)
                            .foregroundStyle(RuneTheme.paperTextMuted)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)

                    // MARK: Crop
                    ImageCropSection(model: model)

                    InspectorDivider()

                    // MARK: Effects
                    BeautifierControlsSection(model: model)

                    InspectorDivider()

                    // MARK: Layout
                    LayoutSection(model: model)

                    InspectorDivider()

                    // MARK: Background
                    BackgroundPickerSection(model: model)
                    }

                    Spacer(minLength: 20)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(RuneTheme.paperBackground)
    }
}

// MARK: - Inspector Components

private enum InspectorPanel: String, CaseIterable, Identifiable {
    case annotation
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .annotation: "标注"
        case .appearance: "美化"
        }
    }
}

private struct InspectorSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        // 图章：Space Mono 小号 + 宽字距，像盖在校样上的工序章
        Text(title)
            .font(RuneFont.mono(size: 10, weight: .medium))
            .foregroundStyle(RuneTheme.paperTextMuted)
            .tracking(1.6)
    }
}

private struct InspectorDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14)
    }
}

private struct InspectorRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(RuneFont.swiftUI(size: 12))
                .foregroundStyle(RuneTheme.paperTextSecondary)
                .frame(width: 52, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnnotationInspectorToolGrid: View {
    let selectedTool: AnnotationTool
    let onSelect: (AnnotationTool) -> Void

    /// 常用工具：顺序、名称与截后悬浮工具栏完全一致，学一次两处都会用。
    /// 注意不放"选择"工具：编辑器里无论当前什么工具，直接点击已画好的标注
    /// 就能选中、拖动、删除，专门的"选择"按钮是多余的。
    private let primaryTools: [AnnotationTool] = [
        .rectangle, .arrow, .text, .blur, .spotlight, .numberedCircle
    ]

    /// 低频图形工具，收进"更多"一行。
    private let secondaryTools: [AnnotationTool] = [
        .ellipse, .line, .filledRectangle, .freehand
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                spacing: 4
            ) {
                ForEach(primaryTools) { tool in
                    primaryToolButton(tool)
                }
            }

            HStack(spacing: 4) {
                Text("更多")
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.paperTextMuted)
                    .frame(width: 30, alignment: .leading)

                ForEach(secondaryTools) { tool in
                    secondaryToolButton(tool)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RuneTheme.paperCard)
        )
    }

    private func primaryToolButton(_ tool: AnnotationTool) -> some View {
        Button {
            onSelect(tool)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.systemImage)
                    .font(RuneFont.swiftUI(size: 14, weight: .medium))
                    .frame(height: 18)

                Text(tool.title)
                    .font(RuneFont.swiftUI(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTool == tool ? RuneTheme.annotationAccent : .primary.opacity(0.72))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectedTool == tool ? RuneTheme.annotationAccent.opacity(0.15) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    selectedTool == tool ? RuneTheme.annotationAccent.opacity(0.35) : .clear,
                    lineWidth: 0.8
                )
        )
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }

    private func secondaryToolButton(_ tool: AnnotationTool) -> some View {
        Button {
            onSelect(tool)
        } label: {
            Image(systemName: tool.systemImage)
                .font(RuneFont.swiftUI(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selectedTool == tool ? RuneTheme.annotationAccent : .primary.opacity(0.55))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selectedTool == tool ? RuneTheme.annotationAccent.opacity(0.15) : .clear)
        )
        .help(tool.title)
        .accessibilityLabel(tool.title)
    }
}

// MARK: - Color Menu

private struct AnnotationColorMenu: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selectedSwatch.color)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))

                Text(selectedSwatch.title)
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.paperInk.opacity(0.8))

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    .foregroundStyle(RuneTheme.paperTextMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(RuneTheme.paperCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("标注颜色：\(selectedSwatch.title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            AnnotationColorPopover(
                selectedSwatch: selectedSwatch,
                onSelect: { swatch in onSelect(swatch); isPresented = false },
                onCustomSelect: onSelect
            )
        }
    }
}

private struct AnnotationColorPopover: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void
    let onCustomSelect: (AnnotationSwatch) -> Void

    private var customColor: Binding<Color> {
        Binding(
            get: { selectedSwatch.color },
            set: { onCustomSelect(.custom(from: $0)) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(AnnotationSwatch.allCases) { swatch in
                Button {
                    onSelect(swatch)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 0.5))
                            .overlay {
                                if selectedSwatch == swatch {
                                    Circle()
                                        .stroke(RuneTheme.annotationAccent.opacity(0.38), lineWidth: 6)
                                        .frame(width: 32, height: 32)
                                }
                            }
                        Text(swatch.title)
                            .font(RuneFont.swiftUI(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 34)
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .background {
                        if selectedSwatch == swatch {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(RuneTheme.annotationAccent.opacity(0.10))
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Divider().padding(.vertical, 4)

            ColorPicker(selection: customColor, supportsOpacity: false) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(AngularGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            center: .center
                        ))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))
                    Text("自定义")
                        .font(RuneFont.swiftUI(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
        }
        .padding(8)
        .frame(width: 172)
    }
}

// MARK: - Stroke Menu

private struct AnnotationStrokeMenu: View {
    let strokeWidth: CGFloat
    let onSelect: (CGFloat) -> Void
    private let widths: [CGFloat] = [2, 4, 6, 8, 12]
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 10) {
                StrokePreview(width: strokeWidth)
                    .frame(width: 30, height: 16)

                Text("\(Int(strokeWidth)) 像素")
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.paperInk.opacity(0.8))
                    .frame(minWidth: 28, alignment: .leading)

                Spacer(minLength: 10)

                Image(systemName: "chevron.up.chevron.down")
                    .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    .foregroundStyle(RuneTheme.paperTextMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(RuneTheme.paperCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(spacing: 7) {
                ForEach(widths, id: \.self) { width in
                    Button {
                        onSelect(width)
                        isPresented = false
                    } label: {
                        ZStack {
                            if strokeWidth == width {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(RuneTheme.annotationAccent.opacity(0.12))
                            }
                            StrokePreview(width: width, color: strokeWidth == width ? RuneTheme.annotationAccent : Color.primary.opacity(0.58))
                                .frame(width: 48, height: 32)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .frame(width: 92)
        }
    }
}

private struct StrokePreview: View {
    let width: CGFloat
    var color: Color = .primary

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: proxy.size.width * 0.24, y: proxy.size.height * 0.68))
                path.addLine(to: CGPoint(x: proxy.size.width * 0.76, y: proxy.size.height * 0.32))
            }
            .stroke(color, style: StrokeStyle(lineWidth: min(width, 7), lineCap: .round))
        }
    }
}

// MARK: - Text Style Controls

private struct AnnotationTextStyleControls: View {
    @Bindable var model: EditorModel
    @State private var fontSizeText = ""
    @FocusState private var isFontSizeFieldFocused: Bool

    private static let fontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted()
    }()

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                fontFamilyMenu
                    .frame(minWidth: 0, maxWidth: .infinity)

                AnnotationColorWellMenu(selectedSwatch: model.selectedSwatch) { swatch in
                    model.setSwatch(swatch)
                }
            }

            HStack(spacing: 6) {
                fontSizeStepper
                Spacer()
                textStyleToggles
                    .frame(width: 96)
            }

            textAlignmentControl
        }
        .frame(maxWidth: .infinity)
        .onAppear(perform: syncFontSizeText)
        .onChange(of: model.selectedTextFontSize) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: model.selectedItemID) { _, _ in
            guard !isFontSizeFieldFocused else { return }
            syncFontSizeText()
        }
        .onChange(of: isFontSizeFieldFocused) { _, isFocused in
            if isFocused { syncFontSizeText() } else { commitFontSizeText() }
        }
    }

    private var fontFamilyMenu: some View {
        RuneMenu(
            menuWidth: 230,
            entries: {
                Self.fontFamilies.map { family in
                    .item(
                        RuneMenuItem(family, isSelected: model.selectedTextFontName == family) {
                            model.selectedTextFontName = family
                        }
                    )
                }
            }
        ) {
            HStack(spacing: 6) {
                Text(model.selectedTextFontName)
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.paperInk.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.up.chevron.down")
                    .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    .foregroundStyle(RuneTheme.paperTextMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(RuneTheme.paperCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(RuneTheme.paperSeparator, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var fontSizeStepper: some View {
        HStack(spacing: 0) {
            Button { adjustFontSize(by: -1) } label: {
                Image(systemName: "minus").font(RuneFont.swiftUI(size: 10, weight: .medium)).frame(width: 22, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(RuneTheme.paperTextSecondary)

            Divider().frame(height: 14)

            TextField("", text: $fontSizeText)
                .focused($isFontSizeFieldFocused)
                .onSubmit(commitFontSizeText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(RuneFont.swiftUI(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 32)

            Divider().frame(height: 14)

            Button { adjustFontSize(by: 1) } label: {
                Image(systemName: "plus").font(RuneFont.swiftUI(size: 10, weight: .medium)).frame(width: 22, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(RuneTheme.paperTextSecondary)
        }
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(RuneTheme.paperCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }

    private var textStyleToggles: some View {
        HStack(spacing: 0) {
            styleToggle("粗", isActive: model.selectedTextIsBold, font: RuneFont.swiftUI(size: 12, weight: .bold)) {
                model.selectedTextIsBold.toggle()
            }
            styleToggle("斜", isActive: model.selectedTextIsItalic, font: RuneFont.swiftUI(size: 12).italic()) {
                model.selectedTextIsItalic.toggle()
            }
            styleToggle("下", isActive: model.selectedTextIsUnderline, font: RuneFont.swiftUI(size: 12), underline: true) {
                model.selectedTextIsUnderline.toggle()
            }
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(RuneTheme.paperCard))
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }

    private func styleToggle(_ label: String, isActive: Bool, font: Font, underline: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(font)
                .underline(underline)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .background { if isActive { Capsule().fill(RuneTheme.paperInk) } }
    }

    private var textAlignmentControl: some View {
        HStack(spacing: 0) {
            alignmentButton(.left, "text.alignleft")
            alignmentButton(.center, "text.aligncenter")
            alignmentButton(.right, "text.alignright")
            alignmentButton(.justified, "text.justify.leading")
        }
        .padding(3)
        .frame(height: 34)
        .background(Capsule().fill(RuneTheme.paperCard))
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5))
    }

    private func alignmentButton(_ alignment: NSTextAlignment, _ icon: String) -> some View {
        let isSelected = model.selectedTextAlignment == alignment
        return Button {
            model.selectedTextAlignment = alignment
        } label: {
            Image(systemName: icon)
                .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.white : RuneTheme.paperInk)
        .background { if isSelected { Capsule().fill(RuneTheme.paperInk) } }
        .accessibilityLabel(alignment.accessibilityName)
    }

    private func syncFontSizeText() {
        fontSizeText = String(Int(model.selectedTextFontSize.rounded()))
    }

    private func commitFontSizeText() {
        let trimmedText = fontSizeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Double(trimmedText) else { syncFontSizeText(); return }
        let clampedSize = max(size.rounded(), Double(AnnotationTextMetrics.minimumFontSize))
        model.selectedTextFontSize = CGFloat(clampedSize)
        fontSizeText = String(Int(clampedSize))
    }

    private func adjustFontSize(by delta: CGFloat) {
        commitFontSizeText()
        let size = max(model.selectedTextFontSize + delta, AnnotationTextMetrics.minimumFontSize)
        model.selectedTextFontSize = size
        syncFontSizeText()
    }
}

private extension NSTextAlignment {
    var accessibilityName: String {
        switch self {
        case .left: "文字左对齐"
        case .center: "文字居中"
        case .right: "文字右对齐"
        case .justified: "文字两端对齐"
        case .natural: "文字自然对齐"
        @unknown default: "文字对齐"
        }
    }
}

private struct AnnotationColorWellMenu: View {
    let selectedSwatch: AnnotationSwatch
    let onSelect: (AnnotationSwatch) -> Void
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(selectedSwatch.color)
                .frame(width: 28, height: 20)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("标注颜色：\(selectedSwatch.title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            AnnotationColorPopover(
                selectedSwatch: selectedSwatch,
                onSelect: { swatch in onSelect(swatch); isPresented = false },
                onCustomSelect: onSelect
            )
        }
    }
}

// MARK: - Layout Section

private struct LayoutSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionHeader("布局")

            HStack(spacing: 10) {
                Text("比例")
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.paperTextSecondary)
                    .frame(width: 52, alignment: .leading)

                RuneMenu(
                    menuWidth: 180,
                    entries: {
                        CanvasAspectRatio.allCases.map { ratio in
                            .item(
                                RuneMenuItem(ratio.displayName, isSelected: model.config.aspectRatio == ratio) {
                                    model.updateConfig { $0.aspectRatio = ratio }
                                }
                            )
                        }
                    }
                ) {
                    HStack(spacing: 6) {
                        Text(model.config.aspectRatio.displayName)
                            .font(RuneFont.swiftUI(size: 12))
                            .foregroundStyle(RuneTheme.paperInk.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                            .foregroundStyle(RuneTheme.paperTextMuted)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(RuneTheme.paperCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(RuneTheme.paperSeparator, lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            HStack(alignment: .top, spacing: 10) {
                Text("对齐")
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.paperTextSecondary)
                    .frame(width: 52, alignment: .leading)
                    .padding(.top, 6)

                AlignmentGridPicker(selection: Binding(
                    get: { model.config.alignment },
                    set: { alignment in model.updateConfig { $0.alignment = alignment } }
                ))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

private struct AlignmentGridPicker: View {
    @Binding var selection: ImageAlignment

    private static let rows: [[ImageAlignment]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, .center, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row, id: \.self) { alignment in
                        Button {
                            selection = alignment
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(selection == alignment ? RuneTheme.annotationAccent.opacity(0.12) : .clear)

                                Circle()
                                    .fill(selection == alignment ? RuneTheme.annotationAccent : Color.primary.opacity(0.22))
                                    .frame(width: selection == alignment ? 9 : 6, height: selection == alignment ? 9 : 6)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("图像位置：\(alignment.displayName)")
                        .accessibilityValue(selection == alignment ? "已选择" : "未选择")
                    }
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(RuneTheme.paperCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Background Picker

struct BackgroundPickerSection: View {
    @Bindable var model: EditorModel

    private let swatchColumns = Array(repeating: GridItem(.fixed(28), spacing: 6), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorSectionHeader("背景")

            Text("纯色")
                .font(RuneFont.caption2)
                .foregroundStyle(RuneTheme.paperTextMuted)

            LazyVGrid(columns: swatchColumns, spacing: 6) {
                noneButton

                ForEach(SolidColor.presets) { color in
                    solidButton(color)
                }
            }

            Text("渐变")
                .font(RuneFont.caption2)
                .foregroundStyle(RuneTheme.paperTextMuted)

            LazyVGrid(columns: swatchColumns, spacing: 6) {
                ForEach(GradientPreset.presets) { preset in
                    gradientButton(preset)
                }
            }

            Text("macOS")
                .font(RuneFont.caption2)
                .foregroundStyle(RuneTheme.paperTextMuted)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 4), spacing: 6) {
                ForEach(BundledBackgrounds.macAssets) { asset in
                    bundledImageButton(asset)
                }
            }

            customImageSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var noneButton: some View {
        Button {
            model.updateConfig { $0.style = .none }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 28, height: 28)
                Path { path in
                    path.move(to: CGPoint(x: 26, y: 2))
                    path.addLine(to: CGPoint(x: 2, y: 26))
                }
                .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        model.config.style == .none ? RuneTheme.annotationAccent : Color.primary.opacity(0.12),
                        lineWidth: model.config.style == .none ? 2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help("无背景")
        .accessibilityLabel("无背景")
    }

    private func solidButton(_ color: SolidColor) -> some View {
        let isSelected: Bool = {
            if case .solid(let c) = model.config.style { return c.id == color.id }
            return false
        }()

        return Button {
            model.updateConfig { $0.style = .solid(color) }
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.color)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? RuneTheme.annotationAccent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(color.name)
        .accessibilityLabel("纯色背景：\(color.name)")
    }

    private func gradientButton(_ preset: GradientPreset) -> some View {
        let isSelected: Bool = {
            if case .gradient(let g) = model.config.style { return g.id == preset.id }
            return false
        }()

        return Button {
            model.updateConfig { $0.style = .gradient(preset) }
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(preset.swiftUIGradient)
                .frame(width: 28, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? RuneTheme.annotationAccent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel("渐变背景：\(preset.name)")
    }

    private func bundledImageButton(_ asset: BundledBackgrounds.ImageAsset) -> some View {
        let isSelected: Bool = {
            if case .bundledImage(let id) = model.config.style { return id == asset.id }
            return false
        }()

        return Button {
            model.updateConfig { $0.style = .bundledImage(asset.id) }
        } label: {
            Group {
                if let image = asset.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 48, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? RuneTheme.annotationAccent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("macOS 背景 \(asset.id.replacingOccurrences(of: "mac-", with: ""))")
    }

    @ViewBuilder
    private var customImageSection: some View {
        if case .wallpaper(let source) = model.config.style {
            HStack(spacing: 6) {
                if let img = NSImage(contentsOfFile: source.path) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(RuneTheme.annotationAccent, lineWidth: 2)
                        )
                }

                Text(URL(fileURLWithPath: source.path).lastPathComponent)
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.paperTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    pickCustomWallpaper()
                } label: {
                    Text("更换")
                        .font(RuneFont.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        } else {
            Button {
                pickCustomWallpaper()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(RuneFont.caption2)
                    Text("自定义图片…").font(RuneFont.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
            }
            .buttonStyle(.plain)
            .foregroundStyle(RuneTheme.paperTextSecondary)
        }
    }

    private func pickCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.title = "选择背景图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        model.updateConfig { $0.style = .wallpaper(WallpaperSource(path: path)) }
    }
}

// MARK: - Crop Section

private struct ImageCropSection: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionHeader("裁剪")

            HStack {
                Button {
                    model.isCropping.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "crop")
                            .font(RuneFont.caption)
                        Text(model.isCropping ? "完成" : "裁剪")
                            .font(RuneFont.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(model.isCropping ? AnyShapeStyle(RuneTheme.annotationAccent.opacity(0.15)) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(model.isCropping ? RuneTheme.annotationAccent : Color.primary.opacity(0.08), lineWidth: model.isCropping ? 1.5 : 0.5)
                    )
                }
                .buttonStyle(.plain)

                if model.hasCrop {
                    Button {
                        model.resetCrop()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(RuneFont.caption)
                            Text("重置")
                                .font(RuneFont.caption2)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }

            if model.hasCrop {
                let w = Int(CGFloat(model.sourceImage?.width ?? 0) * model.cropRect.width)
                let h = Int(CGFloat(model.sourceImage?.height ?? 0) * model.cropRect.height)
                Text("\(w) × \(h)")
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.paperTextMuted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

// MARK: - Beautifier Controls

struct BeautifierControlsSection: View {
    @Bindable var model: EditorModel
    @State private var configBeforeDrag: BeautifierConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSectionHeader("效果")

            LabeledSlider(
                label: "边距",
                value: Binding(get: { model.config.padding }, set: { model.config.padding = $0 }),
                range: 0.0...0.45,
                format: { "\(Int($0 * 100))%" },
                onEditingChanged: { handleSliderEditing($0) }
            )

            LabeledSlider(
                label: "圆角",
                value: Binding(get: { model.config.cornerRadius }, set: { model.config.cornerRadius = $0 }),
                range: 0.0...0.12,
                format: { "\(Int($0 * 1000))" },
                onEditingChanged: { handleSliderEditing($0) }
            )

            LabeledSlider(
                label: "阴影",
                value: Binding(get: { model.config.shadowStrength }, set: { model.config.shadowStrength = $0 }),
                range: 0.0...1.0,
                format: { "\(Int($0 * 100))%" },
                onEditingChanged: { handleSliderEditing($0) }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func handleSliderEditing(_ editing: Bool) {
        if editing {
            configBeforeDrag = model.config
        } else if let saved = configBeforeDrag {
            let current = model.config
            model.config = saved
            model.updateConfig { $0 = current }
            configBeforeDrag = nil
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let format: (CGFloat) -> String
    var onEditingChanged: ((Bool) -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.paperTextMuted)
                Spacer()
                Text(format(value))
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.paperTextMuted)
            }
            Slider(value: $value, in: range) { editing in
                onEditingChanged?(editing)
            }
            .controlSize(.small)
        }
    }
}
