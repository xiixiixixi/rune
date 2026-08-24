import SwiftUI
import Carbon

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case capture = "截图"
    case recording = "录屏"
    case history = "截图记录"
    case videos = "录屏记录"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .history: return "photo.on.rectangle.angled"
        case .videos: return "video.circle"
        case .about: return "info.circle"
        }
    }
}

struct PreferencesView: View {
    @State private var selectedSection: SettingsSection

    init(initialSection: SettingsSection = .general) {
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: selectedSection == section
                    ) {
                        selectedSection = section
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .frame(width: 176)
            .frame(maxHeight: .infinity)
            .background(RuneTheme.background)

            Rectangle()
                .fill(RuneTheme.separator)
                .frame(width: 1)

            Group {
                switch selectedSection {
                case .general:
                    GeneralSettingsTab()
                case .capture:
                    CaptureSettingsTab()
                case .recording:
                    RecordingSettingsTab()
                case .history:
                    HistoryTab()
                case .videos:
                    VideosTab()
                case .about:
                    AboutTab()
                }
            }
            .id(selectedSection)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(RuneTheme.accent)
        .background(RuneTheme.background)
        .frame(minWidth: 680, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 侧栏

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(RuneFont.swiftUI(size: 13, weight: .medium))
                    .frame(width: 18)

                Text(section.rawValue)
                    .font(RuneFont.swiftUI(size: 13, weight: isSelected ? .semibold : .medium))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : RuneTheme.textPrimary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                Group {
                    if isSelected {
                        // 选中态：墨色胶囊——整间车间里最重的一块墨
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(RuneTheme.ink)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    } else {
                        Color.clear
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - 校样卡片骨架

/// 设置页的分区骨架：图章标签 + 白色校样卡。
/// 卡里的控件保持原生（开关、分段选择、滑杆），容器是我们的纸与墨。
private struct ProofSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RuneTheme.stampLabel(title)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RuneTheme.proofCardBackground())
        }
    }
}

/// 设置页滚动容器：瓷白纸面 + 统一页边距
private struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RuneTheme.background)
    }
}

/// 常规行：标签在左，控件在右
private struct SettingsRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    init(_ label: String, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(RuneFont.swiftUI(size: 13))
                .foregroundStyle(RuneTheme.textPrimary)
            Spacer(minLength: 12)
            control()
        }
    }
}

/// 滑杆行：标签 + 等宽读数在上，滑杆在下
private struct SettingsSliderRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label)
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.textSecondary)
                Spacer()
                Text(value)
                    .font(RuneFont.mono(size: 11, weight: .medium))
                    .foregroundStyle(RuneTheme.textSecondary)
            }
        }
    }
}

/// 卡内说明文字
private struct ProofFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(RuneFont.swiftUI(size: 12))
            .foregroundStyle(RuneTheme.textSecondary)
            .lineSpacing(2)
    }
}

/// 恢复默认按钮：安静的次级文字按钮
private struct ResetButton: View {
    let title: String
    let isDestructive: Bool
    let action: () -> Void

    init(_ title: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(RuneFont.swiftUI(size: 12, weight: .medium))
                .foregroundStyle(isDestructive ? RuneTheme.signal : RuneTheme.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(RuneTheme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(RuneTheme.separator, lineWidth: 1)
                )
        }
        .buttonStyle(RuneTheme.RunePressStyle())
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("bs_appAppearance") private var appAppearanceRaw: String = AppAppearance.system.rawValue
    @AppStorage("bs_saveDirectory") private var saveDir = NSHomeDirectory() + "/Desktop"
    @AppStorage("bs_copyAfterSave") private var copyAfterSave = true
    @AppStorage("bs_playSound") private var playSound = true
    @AppStorage("bs_exportFormat") private var exportFormatRaw: String = ExportFormat.png.rawValue
    @AppStorage("bs_exportQuality") private var exportQuality: Double = 0.9
    @AppStorage("bs_fileNameFormat") private var fileNameFormatRaw: String = FileNameFormat.systemStyle.rawValue

    @State private var defaultConfig = AppPreferences.defaultBeautifierConfig

    private var appAppearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appAppearanceRaw) ?? .system },
            set: { newValue in
                appAppearanceRaw = newValue.rawValue
                AppPreferences.applyAppearance()
            }
        )
    }

    private var exportFormat: Binding<ExportFormat> {
        Binding(
            get: { ExportFormat(rawValue: exportFormatRaw) ?? .png },
            set: { exportFormatRaw = $0.rawValue }
        )
    }

    private var saveDirDisplayName: String {
        let url = URL(fileURLWithPath: saveDir)
        return url.lastPathComponent
    }

    var body: some View {
        SettingsScroll {
            ProofSection("外观") {
                SettingsRow("模式") {
                    Picker("模式", selection: appAppearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            ProofSection("保存") {
                SettingsRow("保存到") {
                    HStack(spacing: 8) {
                        Text(saveDirDisplayName)
                            .font(RuneFont.mono(size: 11, weight: .medium))
                            .foregroundStyle(RuneTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            panel.directoryURL = URL(fileURLWithPath: saveDir)
                            if panel.runModal() == .OK, let url = panel.url {
                                saveDir = url.path
                            }
                        }
                        .controlSize(.small)
                    }
                }

                SettingsRow("保存后复制到剪贴板") {
                    Toggle("保存后复制到剪贴板", isOn: $copyAfterSave)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            ProofSection("截图") {
                SettingsRow("播放快门声") {
                    Toggle("播放快门声", isOn: $playSound)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            ProofSection("默认效果") {
                DefaultConfigPreview(config: defaultConfig)
                    .frame(height: 120)

                defaultSlider(label: "边距", value: $defaultConfig.padding, range: 0.0...0.45) {
                    "\(Int($0 * 100))%"
                }
                defaultSlider(label: "圆角", value: $defaultConfig.cornerRadius, range: 0.0...0.12) {
                    "\(Int($0 * 1000))"
                }
                defaultSlider(label: "阴影", value: $defaultConfig.shadowStrength, range: 0.0...1.0) {
                    "\(Int($0 * 100))%"
                }
            }
            .onChange(of: defaultConfig) { _, newValue in
                AppPreferences.defaultBeautifierConfig = newValue
            }

            ProofSection("默认背景") {
                DefaultBackgroundPicker(selectedStyle: $defaultConfig.style)

                HStack {
                    Text(backgroundLabel(for: defaultConfig.style))
                        .font(RuneFont.mono(size: 11, weight: .medium))
                        .foregroundStyle(RuneTheme.textMuted)
                    Spacer()
                    ResetButton("恢复默认效果") {
                        defaultConfig = .default
                        AppPreferences.defaultBeautifierConfig = .default
                    }
                }
            }

            ProofSection("导出") {
                SettingsRow("格式") {
                    Picker("格式", selection: exportFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if exportFormatRaw == ExportFormat.jpeg.rawValue {
                    VStack(spacing: 6) {
                        SettingsSliderRow(label: "质量", value: "\(Int(exportQuality * 100))%")
                        Slider(value: $exportQuality, in: 0.1...1.0, step: 0.05)
                            .controlSize(.small)
                    }
                }

                SettingsRow("文件命名") {
                    Picker("文件命名", selection: Binding(
                        get: { FileNameFormat(rawValue: fileNameFormatRaw) ?? .systemStyle },
                        set: { fileNameFormatRaw = $0.rawValue }
                    )) {
                        ForEach(FileNameFormat.allCases, id: \.self) { fmt in
                            Text(fmt.label).tag(fmt)
                        }
                    }
                    .labelsHidden()
                }
            }

            HStack {
                Spacer()
                ResetButton("恢复全部通用设置", isDestructive: true) {
                    appAppearanceRaw = AppAppearance.system.rawValue
                    AppPreferences.applyAppearance()
                    saveDir = NSHomeDirectory() + "/Desktop"
                    copyAfterSave = true
                    playSound = true
                    exportFormatRaw = ExportFormat.png.rawValue
                    exportQuality = 0.9
                    fileNameFormatRaw = FileNameFormat.systemStyle.rawValue
                    defaultConfig = .default
                    AppPreferences.defaultBeautifierConfig = .default
                }
            }
        }
    }

    private func defaultSlider(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, format: @escaping (CGFloat) -> String) -> some View {
        VStack(spacing: 6) {
            SettingsSliderRow(label: label, value: format(value.wrappedValue))
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func backgroundLabel(for style: BackgroundStyle) -> String {
        switch style {
        case .none: return "透明"
        case .solid(let c): return c.name
        case .gradient(let g): return g.name
        case .wallpaper: return "自定义图片"
        case .bundledImage: return "macOS 壁纸"
        }
    }
}

// MARK: - Default Background Picker (compact for settings)

private struct DefaultBackgroundPicker: View {
    @Binding var selectedStyle: BackgroundStyle

    private let swatchColumns = Array(repeating: GridItem(.fixed(24), spacing: 5), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: swatchColumns, spacing: 5) {
                noneButton
                ForEach(SolidColor.presets) { color in
                    solidButton(color)
                }
            }

            LazyVGrid(columns: swatchColumns, spacing: 5) {
                ForEach(GradientPreset.presets) { preset in
                    gradientButton(preset)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 5), count: 6), spacing: 5) {
                ForEach(BundledBackgrounds.macAssets) { asset in
                    bundledImageButton(asset)
                }
            }

            customImageRow
        }
    }

    private var noneButton: some View {
        Button {
            selectedStyle = .none
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 24, height: 24)
                Path { path in
                    path.move(to: CGPoint(x: 22, y: 2))
                    path.addLine(to: CGPoint(x: 2, y: 22))
                }
                .stroke(RuneTheme.signal.opacity(0.6), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selectedStyle == .none ? RuneTheme.accent : Color.primary.opacity(0.12), lineWidth: selectedStyle == .none ? 2 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("无背景")
    }

    private func solidButton(_ color: SolidColor) -> some View {
        let isSelected: Bool = {
            if case .solid(let c) = selectedStyle { return c.id == color.id }
            return false
        }()

        return Button {
            selectedStyle = .solid(color)
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color.color)
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isSelected ? RuneTheme.accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(color.name)
    }

    private func gradientButton(_ preset: GradientPreset) -> some View {
        let isSelected: Bool = {
            if case .gradient(let g) = selectedStyle { return g.id == preset.id }
            return false
        }()

        return Button {
            selectedStyle = .gradient(preset)
        } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(preset.swiftUIGradient)
                .frame(width: 24, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isSelected ? RuneTheme.accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(preset.name)
    }

    private func bundledImageButton(_ asset: BundledBackgrounds.ImageAsset) -> some View {
        let isSelected: Bool = {
            if case .bundledImage(let id) = selectedStyle { return id == asset.id }
            return false
        }()

        return Button {
            selectedStyle = .bundledImage(asset.id)
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
            .frame(width: 38, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isSelected ? RuneTheme.accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var customImageRow: some View {
        if case .wallpaper(let source) = selectedStyle {
            HStack(spacing: 8) {
                if let img = NSImage(contentsOfFile: source.path) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(RuneTheme.accent, lineWidth: 2)
                        )
                }
                Text(URL(fileURLWithPath: source.path).lastPathComponent)
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("更换") { pickCustomImage() }
                    .controlSize(.mini)
            }
        } else {
            Button { pickCustomImage() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(RuneFont.caption2)
                    Text("自定义图片…").font(RuneFont.caption2)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func pickCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择背景图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedStyle = .wallpaper(WallpaperSource(path: url.path))
    }
}

// MARK: - Default Config Preview

private struct DefaultConfigPreview: View {
    let config: BeautifierConfig

    var body: some View {
        GeometryReader { proxy in
            let mockImageW: CGFloat = 160
            let mockImageH: CGFloat = 100
            let shortEdge = min(mockImageW, mockImageH)
            let pad = shortEdge * config.padding

            var canvasW = mockImageW + pad * 2
            var canvasH = mockImageH + pad * 2
            let _ = {
                if let ratio = config.aspectRatio.numericValue {
                    let current = canvasW / canvasH
                    if current < ratio { canvasW = canvasH * ratio }
                    else { canvasH = canvasW / ratio }
                }
            }()

            let canvasSize = CGSize(width: canvasW, height: canvasH)
            let fitted = aspectFitRect(imageSize: canvasSize, in: proxy.size)

            let totalHPad = canvasW - mockImageW
            let totalVPad = canvasH - mockImageH
            let imgX = fitted.minX + config.alignment.xFactor * totalHPad / canvasW * fitted.width
            let imgY = fitted.minY + config.alignment.yFactor * totalVPad / canvasH * fitted.height
            let imgW = mockImageW / canvasW * fitted.width
            let imgH = mockImageH / canvasH * fitted.height

            let cornerRadius = config.cornerRadius * shortEdge * min(fitted.width / canvasW, fitted.height / canvasH)
            let m = config.alignment.cornerMultipliers

            ZStack {
                previewBackground(config.style)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .position(x: fitted.midX, y: fitted.midY)

                mockScreenshot
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius * m.tl,
                        bottomLeadingRadius: cornerRadius * m.bl,
                        bottomTrailingRadius: cornerRadius * m.br,
                        topTrailingRadius: cornerRadius * m.tr,
                        style: .continuous
                    ))
                    .shadow(
                        color: config.shadowStrength > 0 ? .black.opacity(Double(config.shadowStrength * 0.3)) : .clear,
                        radius: config.shadowStrength > 0 ? max(2, shortEdge * 0.02 * (1 + config.shadowStrength)) : 0,
                        x: 0,
                        y: config.shadowStrength > 0 ? shortEdge * 0.01 * (1 + config.shadowStrength) : 0
                    )
                    .frame(width: imgW, height: imgH)
                    .position(x: imgX + imgW / 2, y: imgY + imgH / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var mockScreenshot: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.96), Color(white: 0.88)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    Circle().fill(.red.opacity(0.7)).frame(width: 5, height: 5)
                    Circle().fill(.yellow.opacity(0.7)).frame(width: 5, height: 5)
                    Circle().fill(.green.opacity(0.7)).frame(width: 5, height: 5)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .padding(.top, 4)

                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.82))
                    .frame(height: 6)
                    .padding(.horizontal, 8)

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.78))
                        .frame(width: 30, height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.84))
                        .frame(height: 4)
                }
                .padding(.horizontal, 8)

                Spacer()
            }
        }
    }

    @ViewBuilder
    private func previewBackground(_ style: BackgroundStyle) -> some View {
        switch style {
        case .none:
            TransparencyGrid()
        case .solid(let color):
            Rectangle().fill(color.color)
        case .gradient(let preset):
            Rectangle().fill(preset.swiftUIGradient)
        case .wallpaper(let source):
            if let nsImage = NSImage(contentsOfFile: source.path) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        case .bundledImage(let assetID):
            if let asset = BundledBackgrounds.asset(byID: assetID),
               let nsImage = asset.image {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Capture Settings

struct CaptureSettingsTab: View {
    @AppStorage("bs_selfTimerDelay") private var selfTimerRaw: Int = 0
    @AppStorage("bs_overlayPosition") private var overlayPositionRaw: String = OverlayPosition.bottomRight.rawValue
    @AppStorage("bs_overlayDismissDelay") private var overlayDismissDelay: Double = 5.0
    @State private var shortcutResetID = UUID()

    private var selfTimerDelay: Binding<SelfTimerDelay> {
        Binding(
            get: { SelfTimerDelay(rawValue: selfTimerRaw) ?? .off },
            set: { selfTimerRaw = $0.rawValue }
        )
    }

    private var overlayPosition: Binding<OverlayPosition> {
        Binding(
            get: { OverlayPosition(rawValue: overlayPositionRaw) ?? .bottomRight },
            set: { overlayPositionRaw = $0.rawValue }
        )
    }

    var body: some View {
        SettingsScroll {
            ProofSection("延时截图") {
                SettingsRow("启动延时") {
                    Picker("延时", selection: selfTimerDelay) {
                        ForEach(SelfTimerDelay.allCases, id: \.self) { delay in
                            Text(delay.label).tag(delay)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            ProofSection("截图预览") {
                SettingsRow("位置") {
                    Picker("位置", selection: overlayPosition) {
                        Text("右下角").tag(OverlayPosition.bottomRight)
                        Text("左下角").tag(OverlayPosition.bottomLeft)
                    }
                    .labelsHidden()
                }

                VStack(spacing: 6) {
                    SettingsSliderRow(label: "自动关闭时间", value: "\(Int(overlayDismissDelay)) 秒")
                    Slider(value: $overlayDismissDelay, in: 2...15, step: 1)
                        .controlSize(.small)
                }
            }

            ProofSection("键盘快捷键") {
                VStack(alignment: .leading, spacing: 8) {
                    ShortcutRow(label: "全局截图", action: .main)
                    ShortcutRow(label: "连拍", action: .burst)
                    ShortcutRow(label: "录屏", action: .recording)
                    ShortcutRow(label: "取色", action: .colorPicker)
                }
                .id(shortcutResetID)

                HStack {
                    Spacer()
                    ResetButton("恢复默认快捷键") {
                        for action in ShortcutService.Action.allCases {
                            let def: ShortcutService.Shortcut? = switch action {
                            case .region: .defaultRegion
                            case .main: .defaultMain
                            case .fullscreen: .defaultFullscreen
                            case .ocr: .defaultOCR
                            case .colorPicker: .defaultColorPicker
                            case .recording: .defaultRecording
                            case .window: .defaultWindow
                            case .burst: .defaultBurst
                            }
                            if let def {
                                ShortcutService.shared.saveShortcut(def, for: action)
                            }
                        }
                        ShortcutService.shared.registerAll()
                        shortcutResetID = UUID()
                    }
                }
            }

            HStack {
                Spacer()
                ResetButton("恢复全部截图设置", isDestructive: true) {
                    selfTimerRaw = 0
                    overlayPositionRaw = OverlayPosition.bottomRight.rawValue
                    overlayDismissDelay = 5.0
                    for action in ShortcutService.Action.allCases {
                        let def: ShortcutService.Shortcut? = switch action {
                        case .region: .defaultRegion
                        case .main: .defaultMain
                        case .fullscreen: .defaultFullscreen
                        case .ocr: .defaultOCR
                        case .colorPicker: .defaultColorPicker
                        case .recording: .defaultRecording
                        case .window: .defaultWindow
                        case .burst: .defaultBurst
                        }
                        if let def {
                            ShortcutService.shared.saveShortcut(def, for: action)
                        }
                    }
                    ShortcutService.shared.registerAll()
                    shortcutResetID = UUID()
                }
            }
        }
    }
}

// MARK: - Recording Settings

struct RecordingSettingsTab: View {
    @AppStorage("bs_recordingFPS") private var recordingFPS: Int = 30
    @AppStorage("bs_recordingShowCursor") private var showCursor: Bool = true
    @AppStorage("bs_recordingCaptureAudio") private var captureAudio: Bool = false

    var body: some View {
        SettingsScroll {
            ProofSection("画质") {
                SettingsRow("帧率") {
                    Picker("帧率", selection: $recordingFPS) {
                        Text("24 帧/秒").tag(24)
                        Text("30 帧/秒").tag(30)
                        Text("60 帧/秒").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                ProofFootnote("帧率越高，视频越流畅，但文件也会更大。")
            }

            ProofSection("录制内容") {
                SettingsRow("录制鼠标指针") {
                    Toggle("录制鼠标指针", isOn: $showCursor)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                SettingsRow("录制系统声音") {
                    Toggle("录制系统声音", isOn: $captureAudio)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            ProofSection("录制完成后") {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RuneTheme.accent)
                    ProofFootnote("先显示轻量结果卡：你可以从结果卡直接剪辑，也可以拖到其他应用或在访达中查看。")
                }
            }

            HStack {
                Spacer()
                ResetButton("恢复全部录屏设置", isDestructive: true) {
                    recordingFPS = 30
                    showCursor = true
                    captureAudio = false
                }
            }
        }
    }
}

struct ShortcutRow: View {
    let label: String
    let action: ShortcutService.Action

    @State private var shortcut: ShortcutService.Shortcut?
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(label)
                .font(RuneFont.swiftUI(size: 13))
                .foregroundStyle(RuneTheme.textPrimary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { shortcut?.enabled ?? false },
                set: { enabled in
                    shortcut?.enabled = enabled
                    if let s = shortcut {
                        ShortcutService.shared.saveShortcut(s, for: action)
                        ShortcutService.shared.registerAll()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            if isRecording {
                ShortcutRecorderView { keyCode, modifiers in
                    shortcut = ShortcutService.Shortcut(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        enabled: shortcut?.enabled ?? true
                    )
                    if let s = shortcut {
                        ShortcutService.shared.saveShortcut(s, for: action)
                        ShortcutService.shared.registerAll()
                    }
                    isRecording = false
                } onCancel: {
                    isRecording = false
                }
                .frame(width: 120, height: 24)
            } else {
                Button {
                    isRecording = true
                } label: {
                    Text(shortcutDisplayString)
                        .font(RuneFont.mono(size: 11, weight: .medium))
                        .foregroundStyle(RuneTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(minWidth: 64)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(RuneTheme.card)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(RuneTheme.separator, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            shortcut = ShortcutService.shared.loadShortcut(for: action) ?? defaultShortcut
        }
    }

    private var defaultShortcut: ShortcutService.Shortcut {
        switch action {
        case .region: return .defaultRegion
        case .main: return .defaultMain
        case .fullscreen: return .defaultFullscreen
        case .window: return .defaultWindow
        case .ocr: return .defaultOCR
        case .colorPicker: return .defaultColorPicker
        case .recording: return .defaultRecording
        case .burst: return .defaultBurst
        }
    }

    private var shortcutDisplayString: String {
        guard let s = shortcut else { return "—" }
        var parts: [String] = []
        if s.modifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        if s.modifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if s.modifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if s.modifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        parts.append(keyCodeToString(s.keyCode))
        return parts.joined()
    }
}

// MARK: - Shortcut Recorder

struct ShortcutRecorderView: NSViewRepresentable {
    let onRecord: (UInt32, UInt32) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutRecorderNSView {
        let view = ShortcutRecorderNSView()
        view.onRecord = onRecord
        view.onCancel = onCancel
        ShortcutService.shared.unregisterAll()
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderNSView, context: Context) {}

    static func dismantleNSView(_ nsView: ShortcutRecorderNSView, coordinator: ()) {
        nsView.removeMonitor()
        ShortcutService.shared.registerAll()
    }
}

final class ShortcutRecorderNSView: NSView {
    var onRecord: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?
    private var eventMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installMonitor()
        }
    }

    private func installMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let keyCode = UInt32(event.keyCode)

            if keyCode == 53 {
                self.onCancel?()
                return nil
            }

            let flags = event.modifierFlags
            var carbonMods: UInt32 = 0
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
            if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
            if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if flags.contains(.control) { carbonMods |= UInt32(controlKey) }

            guard carbonMods != 0 else { return event }

            self.onRecord?(keyCode, carbonMods)
            return nil
        }
    }

    func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        NSColor(RuneTheme.accent).withAlphaComponent(0.12).setFill()
        path.fill()
        NSColor(RuneTheme.accent).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let text = "请按下快捷键…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: RuneFont.appKit(size: 11, weight: .medium),
            .foregroundColor: NSColor(RuneTheme.accent),
        ]
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        text.draw(at: point, withAttributes: attrs)
    }

    override func keyDown(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
}

private func keyCodeToString(_ code: UInt32) -> String {
    let map: [UInt32: String] = [
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F",
        0x04: "H", 0x05: "G", 0x06: "Z", 0x07: "X",
        0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y",
        0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3",
        0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9", 0x1D: "0", 0x1E: "]",
        0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I",
        0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K",
        0x2C: "/", 0x2D: "N", 0x2E: "M",
    ]
    return map[code] ?? "?"
}

// MARK: - History (Screenshots only)

struct HistoryTab: View {
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var confirmsMovingAllToTrash = false
    @State private var copiedRecordID: UUID?

    private var screenshots: [CaptureRecord] {
        HistoryStore.shared.records.filter { $0.kind == .screenshot }
    }

    var body: some View {
        if screenshots.isEmpty {
            ContentUnavailableView("还没有截图", systemImage: "photo.on.rectangle.angled")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    ResetButton("全部移到废纸篓", isDestructive: true) {
                        confirmsMovingAllToTrash = true
                    }
                    .help("把全部截图移到废纸篓，可恢复")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                List {
                    ForEach(screenshots) { record in
                        historyRow(record)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(RuneTheme.separator)
                    .padding(.horizontal, 8)
                }
                .scrollContentBackground(.hidden)
                .background(RuneTheme.background)
            }
            .alert("把全部截图移到废纸篓？", isPresented: $confirmsMovingAllToTrash) {
                Button("移到废纸篓", role: .destructive) {
                    thumbnails.removeAll()
                    screenshots.forEach { HistoryStore.shared.deleteRecord($0) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("之后仍可以从废纸篓恢复。")
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ record: CaptureRecord) -> some View {
        HStack(spacing: 12) {
            if let thumb = thumbnails[record.id.uuidString] {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(width: 64, height: 48)
                    .onAppear {
                        loadThumbnail(for: record)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(RuneFont.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(RuneFont.mono(size: 10))
                    .foregroundStyle(RuneTheme.textSecondary)
                Text(record.createdAt, style: .relative)
                    .font(RuneFont.caption2)
                    .foregroundStyle(RuneTheme.textMuted)
            }

            Spacer()

            recordActions(record, kind: .screenshot)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func recordActions(_ record: CaptureRecord, kind: CaptureKind) -> some View {
        Button {
            let url = HistoryStore.shared.displayURLForRecord(record)
            PreviewOverlay.shared.show(url: url)
        } label: {
            Image(systemName: "eye")
                .font(RuneFont.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RuneTheme.textSecondary)
        .help("预览")

        Button {
            copyRecordToPasteboard(record)
            markCopied(record)
        } label: {
            Image(systemName: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                .font(RuneFont.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(copiedRecordID == record.id ? RuneTheme.accent : RuneTheme.textSecondary)
        .help("复制到剪贴板")

        if kind == .recording {
            Button {
                VideoEditorWindowController.shared.open(url: HistoryStore.shared.urlForRecord(record))
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(RuneFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RuneTheme.textSecondary)
            .help("在编辑器中打开")
        } else {
            Button {
                EditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
            } label: {
                Image(systemName: "pencil")
                    .font(RuneFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RuneTheme.textSecondary)
            .help("在编辑器中打开")
        }

        if kind == .screenshot {
            Button {
                PinnedScreenshotController.shared.pin(
                    url: HistoryStore.shared.displayURLForRecord(record),
                    placement: .bottomRight
                )
            } label: {
                Image(systemName: "pin")
                    .font(RuneFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(RuneTheme.textSecondary)
            .help("贴到屏幕右下角")
        }

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.displayURLForRecord(record)])
        } label: {
            Image(systemName: "folder")
                .font(RuneFont.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RuneTheme.textSecondary)
        .help("在访达中显示")

        Button {
            thumbnails.removeValue(forKey: record.id.uuidString)
            HistoryStore.shared.deleteRecord(record)
        } label: {
            Image(systemName: "trash")
                .font(RuneFont.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(RuneTheme.textSecondary)
        .help("移到废纸篓，可恢复")
    }

    private func markCopied(_ record: CaptureRecord) {
        copiedRecordID = record.id
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            if copiedRecordID == record.id {
                copiedRecordID = nil
            }
        }
    }

    private func loadThumbnail(for record: CaptureRecord) {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let kind = record.kind
        let recordID = record.id.uuidString
        Task {
            let thumb = await Task.detached {
                HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 80)
            }.value
            if let thumb {
                thumbnails[recordID] = NSImage(
                    cgImage: thumb,
                    size: NSSize(width: thumb.width, height: thumb.height)
                )
            }
        }
    }
}

// MARK: - 历史记录共用操作

/// 截图复制图片数据；录屏复制文件（可直接粘贴到聊天窗口发送）。
@MainActor
private func copyRecordToPasteboard(_ record: CaptureRecord) {
    let url = HistoryStore.shared.displayURLForRecord(record)
    let kind = record.kind
    Task.detached(priority: .userInitiated) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if kind == .recording {
            pasteboard.writeObjects([url as NSURL])
        } else if let image = NSImage(contentsOf: url) {
            pasteboard.writeObjects([image])
        }
    }
}

// MARK: - Videos (Recordings only)

struct VideosTab: View {
    @State private var thumbnails: [String: NSImage] = [:]
    @State private var confirmsMovingAllToTrash = false
    @State private var copiedRecordID: UUID?

    private var recordings: [CaptureRecord] {
        HistoryStore.shared.records.filter { $0.kind == .recording }
    }

    var body: some View {
        if recordings.isEmpty {
            ContentUnavailableView("还没有录屏", systemImage: "video.circle")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    ResetButton("全部移到废纸篓", isDestructive: true) {
                        confirmsMovingAllToTrash = true
                    }
                    .help("把全部录屏移到废纸篓，可恢复")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                List {
                    ForEach(recordings) { record in
                        HStack(spacing: 12) {
                            if let thumb = thumbnails[record.id.uuidString] {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 64, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.quaternary)
                                    .frame(width: 64, height: 48)
                                    .onAppear {
                                        loadThumbnail(for: record)
                                    }
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(record.filename)
                                        .font(RuneFont.caption.weight(.medium))
                                        .lineLimit(1)
                                    Image(systemName: "video.fill")
                                        .font(RuneFont.swiftUI(size: 8))
                                        .foregroundStyle(RuneTheme.textSecondary)
                                }
                                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                                    .font(RuneFont.mono(size: 10))
                                    .foregroundStyle(RuneTheme.textSecondary)
                                Text(record.createdAt, style: .relative)
                                    .font(RuneFont.caption2)
                                    .foregroundStyle(RuneTheme.textMuted)
                            }

                            Spacer()

                            Button {
                                let url = HistoryStore.shared.urlForRecord(record)
                                VideoEditorWindowController.shared.open(url: url)
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RuneTheme.textSecondary)
                            .help("在编辑器中打开")

                            Button {
                                copyRecordToPasteboard(record)
                                copiedRecordID = record.id
                                Task {
                                    try? await Task.sleep(for: .milliseconds(1200))
                                    if copiedRecordID == record.id {
                                        copiedRecordID = nil
                                    }
                                }
                            } label: {
                                Image(systemName: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(copiedRecordID == record.id ? RuneTheme.accent : RuneTheme.textSecondary)
                            .help("复制文件到剪贴板")

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.displayURLForRecord(record)])
                            } label: {
                                Image(systemName: "folder")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RuneTheme.textSecondary)
                            .help("在访达中显示")

                            Button {
                                thumbnails.removeValue(forKey: record.id.uuidString)
                                HistoryStore.shared.deleteRecord(record)
                            } label: {
                                Image(systemName: "trash")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(RuneTheme.textSecondary)
                            .help("移到废纸篓，可恢复")
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(RuneTheme.separator)
                    }
                    .padding(.horizontal, 8)
                }
                .scrollContentBackground(.hidden)
                .background(RuneTheme.background)
            }
            .alert("把全部录屏移到废纸篓？", isPresented: $confirmsMovingAllToTrash) {
                Button("移到废纸篓", role: .destructive) {
                    thumbnails.removeAll()
                    recordings.forEach { HistoryStore.shared.deleteRecord($0) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("之后仍可以从废纸篓恢复。")
            }
        }
    }

    private func loadThumbnail(for record: CaptureRecord) {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let kind = record.kind
        let recordID = record.id.uuidString
        Task {
            let thumb = await Task.detached {
                HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 80)
            }.value
            if let thumb {
                thumbnails[recordID] = NSImage(
                    cgImage: thumb,
                    size: NSSize(width: thumb.width, height: thumb.height)
                )
            }
        }
    }
}

// MARK: - About

struct AboutTab: View {
    @AppStorage("rune_automaticallyChecksForUpdates")
    private var automaticallyChecksForUpdates = true

    @State private var updateState: UpdateViewState = .idle

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var appIcon: NSImage? {
        if let icon = NSImage(named: "AppIcon") {
            return icon
        }
        return NSApp.applicationIconImage
    }

    var body: some View {
        SettingsScroll {
            // 头牌校样：裁切角线框住的应用身份块
            HStack(spacing: 16) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Rune")
                        .font(RuneFont.swiftUI(size: 22, weight: .bold))
                        .foregroundStyle(RuneTheme.ink)

                    Text("版本 \(version)（构建 \(build)）")
                        .font(RuneFont.mono(size: 11))
                        .foregroundStyle(RuneTheme.textSecondary)

                    Text("轻量、原生、中文的 macOS 截图工具。")
                        .font(RuneFont.swiftUI(size: 12))
                        .foregroundStyle(RuneTheme.textMuted)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RuneTheme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 0, style: .continuous)
                    .strokeBorder(Color.clear, lineWidth: 0)
            )
            .cropMarks(color: RuneTheme.textMuted.opacity(0.9), lineWidth: 1.2)
            .padding(10)

            ProofSection("软件更新") {
                VStack(alignment: .leading, spacing: 10) {
                    ProofFootnote("发现新版本后会自动下载并完成安装，更新完自动重启，全程不需要手动操作。检查时只读版本号，不上传截图或使用数据。")

                    Toggle("启动后自动检查更新（每天最多一次）", isOn: $automaticallyChecksForUpdates)
                        .font(RuneFont.swiftUI(size: 12))

                    HStack(spacing: 10) {
                        Button(updateState.isChecking ? "正在检查…" : "检查更新") {
                            checkForUpdates()
                        }
                        .disabled(updateState.isChecking)

                        updateStatusView
                    }
                }
            }

            ProofSection("开源致谢") {
                VStack(alignment: .leading, spacing: 8) {
                    ProofFootnote("本软件基于 BetterShot 开源项目独立改造，原项目采用 BSD-3-Clause 许可证。版权说明保留在软件包的 LICENSE 文件中。")
                    ProofFootnote("界面字体 Space Grotesk 与 Space Mono 采用 SIL Open Font License 1.1 授权，随软件附带的 Fonts 目录中保留完整协议文本。")
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle, .checking:
            EmptyView()
        case let .upToDate(latestVersion):
            Label("已是最新版 \(latestVersion)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(RuneTheme.accent)
                .font(RuneFont.swiftUI(size: 12))
        case let .available(update):
            Button("下载 Rune \(update.version)") {
                NSWorkspace.shared.open(update.preferredURL)
            }
            .font(RuneFont.swiftUI(size: 12, weight: .semibold))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(RuneTheme.textSecondary)
                .font(RuneFont.swiftUI(size: 12))
        }
    }

    private func checkForUpdates() {
        updateState = .checking
        Task {
            do {
                switch try await UpdateService.check(currentVersion: version) {
                case let .upToDate(latestVersion):
                    updateState = .upToDate(latestVersion: latestVersion)
                case let .updateAvailable(update):
                    updateState = .idle
                    UpdateWindowController.shared.present(update, currentVersion: version)
                }
            } catch {
                updateState = .failed(
                    message: (error as? LocalizedError)?.errorDescription ?? "检查失败，请稍后再试。"
                )
            }
        }
    }
}

private enum UpdateViewState {
    case idle
    case checking
    case upToDate(latestVersion: String)
    case available(RuneUpdate)
    case failed(message: String)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}
