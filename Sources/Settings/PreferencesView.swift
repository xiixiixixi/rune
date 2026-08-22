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
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .frame(width: 170)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))

            Divider()

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
        .frame(minWidth: 680, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Capsule()
                    .fill(isSelected ? RuneTheme.accent : Color.clear)
                    .frame(width: 3, height: 18)

                Image(systemName: section.icon)
                    .frame(width: 18)

                Text(section.rawValue)
                    .font(RuneFont.swiftUI(size: 13, weight: isSelected ? .semibold : .regular))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? RuneTheme.accent : Color.primary.opacity(0.78))
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                isSelected
                    ? RuneTheme.accent.opacity(0.10)
                    : (isHovered ? Color.primary.opacity(0.055) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        Form {
            Section("外观") {
                Picker("模式", selection: appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("保存") {
                HStack {
                    Text("保存到")
                    Spacer()
                    Text(saveDirDisplayName)
                        .foregroundStyle(.secondary)
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

                Toggle("保存后复制到剪贴板", isOn: $copyAfterSave)
            }

            Section("截图") {
                Toggle("播放快门声", isOn: $playSound)
            }

            Section("默认效果") {
                DefaultConfigPreview(config: defaultConfig)
                    .frame(height: 120)
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))

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

            Section {
                DefaultBackgroundPicker(selectedStyle: $defaultConfig.style)

                Button("恢复默认效果") {
                    defaultConfig = .default
                    AppPreferences.defaultBeautifierConfig = .default
                }
                .controlSize(.small)
                .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("默认背景")
                    Spacer()
                    Text(backgroundLabel(for: defaultConfig.style))
                        .font(RuneFont.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.none)
                }
            }

            Section("导出") {
                Picker("格式", selection: exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                if exportFormatRaw == ExportFormat.jpeg.rawValue {
                    Slider(value: $exportQuality, in: 0.1...1.0, step: 0.05) {
                        Text("质量：\(Int(exportQuality * 100))%")
                    }
                }

                // M2 自动命名保存：文件名格式选择
                Picker("文件命名", selection: Binding(
                    get: { FileNameFormat(rawValue: fileNameFormatRaw) ?? .systemStyle },
                    set: { fileNameFormatRaw = $0.rawValue }
                )) {
                    ForEach(FileNameFormat.allCases, id: \.self) { fmt in
                        Text(fmt.label).tag(fmt)
                    }
                }
            }

            Section {
                Button("恢复全部通用设置") {
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
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    private func defaultSlider(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, format: @escaping (CGFloat) -> String) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(RuneFont.caption)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(RuneFont.caption)
                    .foregroundStyle(.secondary)
            }
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
                .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selectedStyle == .none ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selectedStyle == .none ? 2 : 0.5)
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
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
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
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
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
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 0.5)
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
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                        )
                }
                Text(URL(fileURLWithPath: source.path).lastPathComponent)
                    .font(RuneFont.caption2)
                    .foregroundStyle(.secondary)
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
        Form {
            Section("延时截图") {
                Picker("延时", selection: selfTimerDelay) {
                    ForEach(SelfTimerDelay.allCases, id: \.self) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("截图预览") {
                Picker("位置", selection: overlayPosition) {
                    Text("右下角").tag(OverlayPosition.bottomRight)
                    Text("左下角").tag(OverlayPosition.bottomLeft)
                }

                HStack {
                    Text("自动关闭时间")
                    Spacer()
                    Text("\(Int(overlayDismissDelay)) 秒")
                        .font(RuneFont.caption)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $overlayDismissDelay, in: 2...15, step: 1)
                    .controlSize(.small)
            }

            Section("键盘快捷键") {
                VStack(alignment: .leading, spacing: 8) {
                    ShortcutRow(label: "全局截图", action: .main)
                    ShortcutRow(label: "连拍", action: .burst)
                    ShortcutRow(label: "录屏", action: .recording)
                    ShortcutRow(label: "取色", action: .colorPicker)
                }
                .id(shortcutResetID)

                Button("恢复默认快捷键") {
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
                .controlSize(.small)
            }

            Section {
                Button("恢复全部截图设置") {
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
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Recording Settings

struct RecordingSettingsTab: View {
    @AppStorage("bs_recordingFPS") private var recordingFPS: Int = 30
    @AppStorage("bs_recordingShowCursor") private var showCursor: Bool = true
    @AppStorage("bs_recordingCaptureAudio") private var captureAudio: Bool = false

    var body: some View {
        Form {
            Section("画质") {
                Picker("帧率", selection: $recordingFPS) {
                    Text("24 帧/秒").tag(24)
                    Text("30 帧/秒").tag(30)
                    Text("60 帧/秒").tag(60)
                }
                .pickerStyle(.segmented)

                Text("帧率越高，视频越流畅，但文件也会更大。")
                    .font(RuneFont.caption)
                    .foregroundStyle(.secondary)
            }

            Section("录制内容") {
                Toggle("录制鼠标指针", isOn: $showCursor)
                Toggle("录制系统声音", isOn: $captureAudio)
            }

            Section("录制完成后") {
                Label("先显示轻量结果卡", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(RuneTheme.accent)
                Text("你可以从结果卡直接剪辑，也可以拖到其他应用或在访达中查看。")
                    .font(RuneFont.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("恢复全部录屏设置") {
                    recordingFPS = 30
                    showCursor = true
                    captureAudio = false
                }
                .controlSize(.small)
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
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
                .frame(width: 100, alignment: .leading)

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

            Spacer()

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
                        .font(RuneFont.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(minWidth: 60)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let text = "请按下快捷键…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: RuneFont.appKit(size: 11, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor,
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
                    Button(role: .destructive) {
                        confirmsMovingAllToTrash = true
                    } label: {
                        Label("全部移到废纸篓", systemImage: "trash")
                            .font(RuneFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .help("把全部截图移到废纸篓，可恢复")
                }

                List {
                    ForEach(screenshots) { record in
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
                                    .font(RuneFont.caption2)
                                    .foregroundStyle(.secondary)
                                Text(record.createdAt, style: .relative)
                                    .font(RuneFont.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Button {
                                let url = HistoryStore.shared.displayURLForRecord(record)
                                PreviewOverlay.shared.show(url: url)
                            } label: {
                                Image(systemName: "eye")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("预览")

                            Button {
                                copyRecordToPasteboard(record)
                                markCopied(record)
                            } label: {
                                Image(systemName: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(copiedRecordID == record.id ? Color.accentColor : Color.secondary)
                            .help("复制到剪贴板")

                            Button {
                                EditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
                            } label: {
                                Image(systemName: "pencil")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("在编辑器中打开")

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
                            .foregroundStyle(.secondary)
                            .help("贴到屏幕右下角")

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.displayURLForRecord(record)])
                            } label: {
                                Image(systemName: "folder")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("在访达中显示")

                            Button {
                                thumbnails.removeValue(forKey: record.id.uuidString)
                                HistoryStore.shared.deleteRecord(record)
                            } label: {
                                Image(systemName: "trash")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("移到废纸篓，可恢复")
                        }
                        .padding(.vertical, 2)
                    }
                }
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
                    Button(role: .destructive) {
                        confirmsMovingAllToTrash = true
                    } label: {
                        Label("全部移到废纸篓", systemImage: "trash")
                            .font(RuneFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .help("把全部录屏移到废纸篓，可恢复")
                }

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
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                                    .font(RuneFont.caption2)
                                    .foregroundStyle(.secondary)
                                Text(record.createdAt, style: .relative)
                                    .font(RuneFont.caption2)
                                    .foregroundStyle(.tertiary)
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
                            .foregroundStyle(.secondary)
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
                            .foregroundStyle(copiedRecordID == record.id ? Color.accentColor : Color.secondary)
                            .help("复制文件到剪贴板")

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.displayURLForRecord(record)])
                            } label: {
                                Image(systemName: "folder")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("在访达中显示")

                            Button {
                                thumbnails.removeValue(forKey: record.id.uuidString)
                                HistoryStore.shared.deleteRecord(record)
                            } label: {
                                Image(systemName: "trash")
                                    .font(RuneFont.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("移到废纸篓，可恢复")
                        }
                        .padding(.vertical, 2)
                    }
                }
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
    private var automaticallyChecksForUpdates = false

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header: icon + name
                HStack(spacing: 14) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rune")
                            .font(RuneFont.swiftUI(size: 20, weight: .bold))

                        Text("版本 \(version)（构建 \(build)）")
                            .font(RuneFont.swiftUI(size: 12))
                            .foregroundStyle(.secondary)

                        Text("轻量、原生、中文的 macOS 截图工具。")
                            .font(RuneFont.swiftUI(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, 20)

                aboutSection("软件更新") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("只连接 Rune 自己的 GitHub Release，不使用 BetterShot 的更新服务。检查时只查询版本号，不会上传截图或使用数据。")
                            .font(RuneFont.swiftUI(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)

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

                aboutSection("开源致谢") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本软件基于 BetterShot 开源项目独立改造，原项目采用 BSD-3-Clause 许可证。版权说明保留在软件包的 LICENSE 文件中。")
                            .font(RuneFont.swiftUI(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle, .checking:
            EmptyView()
        case let .upToDate(latestVersion):
            Label("已是最新版 \(latestVersion)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(RuneFont.swiftUI(size: 12))
        case let .available(update):
            Button("下载 Rune \(update.version)") {
                NSWorkspace.shared.open(update.preferredURL)
            }
            .font(RuneFont.swiftUI(size: 12, weight: .semibold))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
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
                    updateState = .available(update)
                }
            } catch {
                updateState = .failed(
                    message: (error as? LocalizedError)?.errorDescription ?? "检查失败，请稍后再试。"
                )
            }
        }
    }

    private func aboutSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(RuneFont.swiftUI(size: 13, weight: .bold))
                .padding(.bottom, 10)

            content()
                .padding(.leading, 2)
                .padding(.bottom, 20)
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
