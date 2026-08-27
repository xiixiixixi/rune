import SwiftUI
import Carbon

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case capture = "截图"
    case recording = "录屏"
    case about = "关于"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .capture: return "camera.viewfinder"
        case .recording: return "record.circle"
        case .about: return "info.circle"
        }
    }

    var toolbarIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("Rune.Settings.\(String(describing: self))")
    }

    init?(toolbarIdentifier: NSToolbarItem.Identifier) {
        self.init(
            rawValue: SettingsSection.allCases.first {
                $0.toolbarIdentifier == toolbarIdentifier
            }?.rawValue ?? ""
        )
    }

    var toolbarHelp: String {
        switch self {
        case .general: return "保存、导出与默认外观"
        case .capture: return "截图行为与快捷键"
        case .recording: return "录屏画面与声音"
        case .about: return "版本、更新与许可"
        }
    }
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published var selection: SettingsSection {
        didSet {
            guard selection != oldValue else { return }
            onSelectionChange?(selection)
        }
    }

    var onSelectionChange: ((SettingsSection) -> Void)?

    init(initialSection: SettingsSection) {
        selection = initialSection
    }
}

struct PreferencesView: View {
    @ObservedObject private var navigationModel: SettingsNavigationModel

    init(initialSection: SettingsSection = .general) {
        _navigationModel = ObservedObject(
            wrappedValue: SettingsNavigationModel(initialSection: initialSection)
        )
    }

    init(navigationModel: SettingsNavigationModel) {
        _navigationModel = ObservedObject(wrappedValue: navigationModel)
    }

    var body: some View {
        Group {
            switch navigationModel.selection {
            case .general:
                GeneralSettingsTab()
            case .capture:
                CaptureSettingsTab()
            case .recording:
                RecordingSettingsTab()
            case .about:
                AboutTab()
            }
        }
        .id(navigationModel.selection)
        .tint(.accentColor)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 880, minHeight: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 页面骨架

private struct SettingsPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .padding(.bottom, 4)
    }
}

private struct ProofSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.5)
            )
        }
    }
}

private struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                content()
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(1)
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
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Text(title)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(isDestructive ? .red : .accentColor)
    }
}

private struct RecordActionButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    var isDestructive = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    isDestructive
                        ? Color.red
                        : (isActive ? Color.accentColor : Color.secondary)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(
                            isActive
                                ? Color.accentColor.opacity(0.12)
                                : (isHovered ? Color.primary.opacity(0.07) : Color.clear)
                        )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct RecordLibraryEmptyState: View {
    let title: String
    let detail: String
    let systemImage: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(.regularMaterial, in: Circle())

            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 430)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("bs_saveDirectory") private var saveDir = NSHomeDirectory() + "/Desktop"
    @AppStorage("bs_copyAfterSave") private var copyAfterSave = true
    @AppStorage("bs_playSound") private var playSound = true
    @AppStorage("bs_exportFormat") private var exportFormatRaw: String = ExportFormat.png.rawValue
    @AppStorage("bs_exportQuality") private var exportQuality: Double = 0.9
    @AppStorage("bs_fileNameFormat") private var fileNameFormatRaw: String = FileNameFormat.systemStyle.rawValue

    @State private var defaultConfig = AppPreferences.defaultBeautifierConfig
    @State private var confirmsReset = false

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
            SettingsPageHeader(title: "通用", subtitle: "设置截图的默认外观、保存位置和文件格式。")

            HStack(alignment: .top, spacing: 18) {
                ProofSection("默认效果") {
                    DefaultConfigPreview(config: defaultConfig)
                        .frame(height: 250)
                        .padding(.vertical, 12)
                }
                .frame(width: 396)

                ProofSection("画面") {
                    VStack(spacing: 14) {
                        defaultSlider(label: "边距", value: $defaultConfig.padding, range: 0.0...0.45) {
                            "\(Int($0 * 100))%"
                        }
                        Divider()
                        defaultSlider(label: "圆角", value: $defaultConfig.cornerRadius, range: 0.0...0.12) {
                            "\(Int($0 * 1000))"
                        }
                        Divider()
                        defaultSlider(label: "阴影", value: $defaultConfig.shadowStrength, range: 0.0...1.0) {
                            "\(Int($0 * 100))%"
                        }
                        Divider()
                        HStack {
                            Text(backgroundLabel(for: defaultConfig.style))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            ResetButton("恢复默认效果") {
                                defaultConfig = .default
                                AppPreferences.defaultBeautifierConfig = .default
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: defaultConfig) { _, newValue in
                AppPreferences.defaultBeautifierConfig = newValue
            }

            ProofSection("保存与导出") {
                SettingsRow("保存到") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(saveDirDisplayName)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("选择…") { chooseSaveDirectory() }
                            .controlSize(.small)
                    }
                }

                SettingsRow("保存后复制到剪贴板") {
                    Toggle("保存后复制到剪贴板", isOn: $copyAfterSave)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsRow("播放快门声") {
                    Toggle("播放快门声", isOn: $playSound)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsRow("导出格式") {
                    Picker("格式", selection: exportFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }

                if exportFormatRaw == ExportFormat.jpeg.rawValue {
                    VStack(spacing: 8) {
                        SettingsSliderRow(label: "JPEG 质量", value: "\(Int(exportQuality * 100))%")
                        Slider(value: $exportQuality, in: 0.1...1.0, step: 0.05)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.45))
                            .frame(height: 0.5)
                    }
                }

                SettingsRow("文件命名") {
                    Picker("文件命名", selection: Binding(
                        get: { FileNameFormat(rawValue: fileNameFormatRaw) ?? .systemStyle },
                        set: { fileNameFormatRaw = $0.rawValue }
                    )) {
                        ForEach(FileNameFormat.allCases, id: \.self) { format in
                            Text(format.label).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            ProofSection("默认背景") {
                DefaultBackgroundPicker(selectedStyle: $defaultConfig.style)
                    .padding(.vertical, 12)
            }

            HStack {
                Spacer()
                ResetButton("恢复全部通用设置") {
                    confirmsReset = true
                }
            }
        }
        .alert("恢复全部通用设置？", isPresented: $confirmsReset) {
            Button("恢复默认设置", role: .destructive) {
                saveDir = NSHomeDirectory() + "/Desktop"
                copyAfterSave = true
                playSound = true
                exportFormatRaw = ExportFormat.png.rawValue
                exportQuality = 0.9
                fileNameFormatRaw = FileNameFormat.systemStyle.rawValue
                defaultConfig = .default
                AppPreferences.defaultBeautifierConfig = .default
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("保存位置、导出格式和默认画面效果都会恢复为初始状态。")
        }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: saveDir)
        if panel.runModal() == .OK, let url = panel.url {
            saveDir = url.path
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
            if let image = BundledBackgrounds.asset(byID: "mac-3")?.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(white: 0.96), Color(white: 0.88)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            LinearGradient(
                colors: [.black.opacity(0.02), .black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
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

private struct CaptureResultPreview: View {
    let timer: SelfTimerDelay
    let overlayPosition: OverlayPosition
    let dismissDelay: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: overlayPosition == .bottomRight ? .bottomTrailing : .bottomLeading) {
                Group {
                    if let image = BundledBackgrounds.asset(byID: "mac-3")?.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RuneTheme.paperControl
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()

                if timer != .off {
                    Label("按下快捷键后 \(timer.label) 截图", systemImage: "timer")
                        .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                        .foregroundStyle(RuneTheme.chromeText)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RuneTheme.chromeBase.opacity(0.88), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(14)
                }

                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(RuneTheme.chromeBlue)
                        Text("截图已保存")
                            .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                            .foregroundStyle(RuneTheme.chromeText)
                        Spacer(minLength: 0)
                        Text("\(Int(dismissDelay)) 秒")
                            .font(RuneFont.mono(size: 8, weight: .medium))
                            .foregroundStyle(RuneTheme.chromeMuted)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)

                    Group {
                        if let image = BundledBackgrounds.asset(byID: "mac-3")?.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            RuneTheme.chromeBase
                        }
                    }
                    .frame(width: 154, height: 78)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    HStack(spacing: 8) {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(RuneFont.swiftUI(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .background(RuneTheme.chromeBlueFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                        Spacer(minLength: 0)

                        Image(systemName: "pin")
                        Image(systemName: "pencil")
                    }
                    .font(RuneFont.swiftUI(size: 9, weight: .semibold))
                    .foregroundStyle(RuneTheme.chromeMuted)
                    .padding(.horizontal, 9)
                    .frame(height: 36)
                }
                .frame(width: 174)
                .background(RuneTheme.chromeElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(RuneTheme.chromeLine, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
                .padding(16)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct CaptureSettingsTab: View {
    @AppStorage("bs_selfTimerDelay") private var selfTimerRaw: Int = 0
    @AppStorage("bs_overlayPosition") private var overlayPositionRaw: String = OverlayPosition.bottomRight.rawValue
    @AppStorage("bs_overlayDismissDelay") private var overlayDismissDelay: Double = 5.0
    @AppStorage("rune_detectUIElements") private var detectUIElements = true
    @State private var accessibilityGranted = UIElementDetector.isTrusted
    @State private var shortcutResetID = UUID()
    @State private var confirmsReset = false

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
            SettingsPageHeader(title: "截图", subtitle: "调整截图前的延时，以及完成后的预览方式和快捷键。")

            ProofSection("效果预览") {
                CaptureResultPreview(
                    timer: selfTimerDelay.wrappedValue,
                    overlayPosition: overlayPosition.wrappedValue,
                    dismissDelay: overlayDismissDelay
                )
                .frame(height: 260)
                .padding(.vertical, 12)
            }

            HStack(alignment: .top, spacing: 18) {
                ProofSection("截图前") {
                    SettingsRow("启动延时") {
                        Picker("延时", selection: selfTimerDelay) {
                            ForEach(SelfTimerDelay.allCases, id: \.self) { delay in
                                Text(delay.label).tag(delay)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                    }
                    ProofFootnote("延时从按下截图快捷键后开始计算。")
                        .padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity)

                ProofSection("完成后") {
                    SettingsRow("预览位置") {
                        Picker("预览位置", selection: overlayPosition) {
                            Text("右下角").tag(OverlayPosition.bottomRight)
                            Text("左下角").tag(OverlayPosition.bottomLeft)
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }

                    VStack(spacing: 8) {
                        SettingsSliderRow(label: "停留时间", value: "\(Int(overlayDismissDelay)) 秒")
                        Slider(value: $overlayDismissDelay, in: 2...15, step: 1)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity)
            }

            ProofSection("智能识别") {
                SettingsRow("识别窗口内部区域") {
                    Toggle("", isOn: $detectUIElements)
                        .labelsHidden()
                }

                if detectUIElements {
                    HStack(spacing: 10) {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "lock.open")
                            .foregroundStyle(accessibilityGranted ? Color.green : Color.secondary)
                        Text(accessibilityGranted ? "辅助功能权限已允许" : "需要一次辅助功能权限")
                            .font(.subheadline)
                        Spacer()
                        if !accessibilityGranted {
                            Button("前往允许") {
                                UIElementDetector.requestAccess()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 8)
                }

                ProofFootnote("用于识别弹窗、卡片和窗内面板。Rune 只读取控件角色与边界，不读取输入内容；未允许时仍可正常识别应用窗口。")
                    .padding(.vertical, 8)
            }

            ProofSection("键盘快捷键") {
                VStack(spacing: 0) {
                    HStack(spacing: 36) {
                        ShortcutRow(label: "全局截图", action: .main)
                        ShortcutRow(label: "连拍", action: .burst)
                    }
                    HStack(spacing: 36) {
                        ShortcutRow(label: "录屏", action: .recording)
                        ShortcutRow(label: "取色", action: .colorPicker)
                    }
                }
                .id(shortcutResetID)

                HStack {
                    ProofFootnote("关闭开关会停用对应快捷键；点击按键组合可以重新录入。")
                    Spacer()
                    ResetButton("恢复默认快捷键") {
                        restoreDefaultShortcuts()
                    }
                }
                .padding(.top, 10)
            }

            HStack {
                Spacer()
                ResetButton("恢复全部截图设置") {
                    confirmsReset = true
                }
            }
        }
        .alert("恢复全部截图设置？", isPresented: $confirmsReset) {
            Button("恢复默认设置", role: .destructive) {
                selfTimerRaw = 0
                overlayPositionRaw = OverlayPosition.bottomRight.rawValue
                overlayDismissDelay = 5.0
                detectUIElements = true
                restoreDefaultShortcuts()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("截图延时、预览方式和所有截图快捷键都会恢复为初始状态。")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityGranted = UIElementDetector.isTrusted
        }
    }

    private func restoreDefaultShortcuts() {
        for action in ShortcutService.Action.allCases {
            let shortcut: ShortcutService.Shortcut = switch action {
            case .region: .defaultRegion
            case .main: .defaultMain
            case .fullscreen: .defaultFullscreen
            case .ocr: .defaultOCR
            case .colorPicker: .defaultColorPicker
            case .recording: .defaultRecording
            case .window: .defaultWindow
            case .burst: .defaultBurst
            }
            ShortcutService.shared.saveShortcut(shortcut, for: action)
        }
        ShortcutService.shared.registerAll()
        shortcutResetID = UUID()
    }
}

// MARK: - Recording Settings

private struct RecordingResultPreview: View {
    let fps: Int
    let showCursor: Bool
    let captureAudio: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Group {
                    if let image = BundledBackgrounds.asset(byID: "mac-3")?.image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RuneTheme.paperControl
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()

                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(RuneTheme.signal)
                            .frame(width: 7, height: 7)
                        Text("录制中")
                            .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                            .foregroundStyle(RuneTheme.chromeText)
                    }

                    Rectangle()
                        .fill(RuneTheme.chromeLine)
                        .frame(width: 1, height: 18)

                    Text("00:00:08")
                        .font(RuneFont.mono(size: 10, weight: .medium))
                        .foregroundStyle(RuneTheme.chromeText)

                    Spacer()

                    Text("\(fps) 帧/秒")
                        .font(RuneFont.mono(size: 9, weight: .medium))
                        .foregroundStyle(RuneTheme.chromeMuted)

                    if captureAudio {
                        Image(systemName: "speaker.wave.2.fill")
                            .accessibilityLabel("录制系统声音")
                    } else {
                        Image(systemName: "speaker.slash.fill")
                            .accessibilityLabel("不录制系统声音")
                    }

                    if showCursor {
                        Image(systemName: "cursorarrow")
                            .accessibilityLabel("录制鼠标指针")
                    }
                }
                .font(RuneFont.swiftUI(size: 11, weight: .medium))
                .foregroundStyle(RuneTheme.chromeText)
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(RuneTheme.chromeBase.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .padding(14)

                if showCursor {
                    Image(systemName: "cursorarrow")
                        .font(RuneFont.swiftUI(size: 25, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .offset(x: 74, y: -72)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

struct RecordingSettingsTab: View {
    @AppStorage("bs_recordingFPS") private var recordingFPS: Int = 30
    @AppStorage("bs_recordingShowCursor") private var showCursor: Bool = true
    @AppStorage("bs_recordingCaptureAudio") private var captureAudio: Bool = false
    @State private var confirmsReset = false

    var body: some View {
        SettingsScroll {
            SettingsPageHeader(title: "录屏", subtitle: "选择录制帧率，并决定是否包含鼠标指针和系统声音。")

            ProofSection("效果预览") {
                RecordingResultPreview(
                    fps: recordingFPS,
                    showCursor: showCursor,
                    captureAudio: captureAudio
                )
                .frame(height: 260)
                .padding(.vertical, 12)
            }

            HStack(alignment: .top, spacing: 18) {
                ProofSection("画面") {
                    SettingsRow("帧率") {
                        Picker("帧率", selection: $recordingFPS) {
                            Text("24 帧/秒").tag(24)
                            Text("30 帧/秒").tag(30)
                            Text("60 帧/秒").tag(60)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 230)
                    }

                    ProofFootnote("30 帧适合大多数演示；60 帧更流畅，也会生成更大的文件。")
                        .padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity)

                ProofSection("录制内容") {
                    SettingsRow("鼠标指针") {
                        Toggle("录制鼠标指针", isOn: $showCursor)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    SettingsRow("系统声音") {
                        Toggle("录制系统声音", isOn: $captureAudio)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                ResetButton("恢复全部录屏设置") {
                    confirmsReset = true
                }
            }
        }
        .alert("恢复全部录屏设置？", isPresented: $confirmsReset) {
            Button("恢复默认设置", role: .destructive) {
                recordingFPS = 30
                showCursor = true
                captureAudio = false
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("帧率、鼠标指针和系统声音设置都会恢复为初始状态。")
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
                .font(.body)
                .foregroundStyle(.primary)

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
                Button(shortcutDisplayString) {
                    isRecording = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .frame(minWidth: 72)
            }
        }
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
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
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let text = "请按下快捷键…" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
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
    @State private var hoveredRecordID: UUID?

    private var screenshots: [CaptureRecord] {
        HistoryStore.shared.records.filter { $0.kind == .screenshot }
    }

    var body: some View {
        SettingsScroll {
            HStack(alignment: .bottom) {
                SettingsPageHeader(title: "截图记录", subtitle: "最近保存的截图")
                Spacer()
                Text("\(screenshots.count) 张")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.bottom, 10)
                if !screenshots.isEmpty {
                    ResetButton("全部移到废纸篓", isDestructive: true) {
                        confirmsMovingAllToTrash = true
                    }
                    .help("把全部截图移到废纸篓，可恢复")
                }
            }

            if screenshots.isEmpty {
                RecordLibraryEmptyState(
                    title: "还没有截图",
                    detail: "完成第一张截图后，它会自动出现在这里。",
                    systemImage: "photo.on.rectangle.angled",
                    actionTitle: "开始截图",
                    action: beginScreenshot
                )
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 250, maximum: 340), spacing: 20),
                        count: 3
                    ),
                    spacing: 22
                ) {
                    ForEach(screenshots) { record in
                        historyTile(record)
                    }
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

    @ViewBuilder
    private func historyTile(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                copyRecordToPasteboard(record)
                markCopied(record)
            } label: {
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .underPageBackgroundColor))

                        if let thumb = thumbnails[record.id.uuidString] {
                            GeometryReader { proxy in
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .clipped()
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .onAppear { loadThumbnail(for: record) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipped()

                    if hoveredRecordID == record.id || copiedRecordID == record.id {
                        Label(
                            copiedRecordID == record.id ? "已复制到剪贴板" : "点击复制",
                            systemImage: copiedRecordID == record.id ? "checkmark" : "doc.on.doc"
                        )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(.black.opacity(0.72))
                            )
                            .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("复制 \(record.filename) 到剪贴板")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.filename)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(record.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                recordActions(record, kind: .screenshot)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
        .onHover { hovering in
            hoveredRecordID = hovering ? record.id : nil
        }
    }

    @ViewBuilder
    private func recordActions(_ record: CaptureRecord, kind: CaptureKind) -> some View {
        if kind == .recording {
            RecordActionButton(title: "在编辑器中打开", systemImage: "slider.horizontal.3") {
                VideoEditorWindowController.shared.open(url: HistoryStore.shared.urlForRecord(record))
            }
        } else {
            RecordActionButton(title: "在编辑器中打开", systemImage: "pencil") {
                EditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
            }
        }

        if kind == .screenshot {
            RecordActionButton(title: "贴到屏幕右下角", systemImage: "pin") {
                PinnedScreenshotController.shared.pin(
                    url: HistoryStore.shared.displayURLForRecord(record),
                    placement: .bottomRight
                )
            }
        }

        Spacer(minLength: 0)

        Menu {
            Button {
                let url = HistoryStore.shared.displayURLForRecord(record)
                PreviewOverlay.shared.show(url: url)
            } label: {
                Label("快速查看", systemImage: "eye")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([
                    HistoryStore.shared.displayURLForRecord(record),
                ])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Divider()

            Button(role: .destructive) {
                thumbnails.removeValue(forKey: record.id.uuidString)
                HistoryStore.shared.deleteRecord(record)
            } label: {
                Label("移到废纸篓", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")
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
                HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 520)
            }.value
            if let thumb {
                thumbnails[recordID] = NSImage(
                    cgImage: thumb,
                    size: NSSize(width: thumb.width, height: thumb.height)
                )
            }
        }
    }

    @MainActor
    private func beginScreenshot() {
        let screen = NSScreen.main
        SettingsWindowController.shared.close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            await CaptureOrchestrator.shared.performCapture(.main, on: screen)
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
        SettingsScroll {
            HStack(alignment: .bottom) {
                SettingsPageHeader(title: "录屏记录", subtitle: "最近保存的录屏")
                Spacer()
                Text("\(recordings.count) 段")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.bottom, 10)
                if !recordings.isEmpty {
                    ResetButton("全部移到废纸篓", isDestructive: true) {
                        confirmsMovingAllToTrash = true
                    }
                    .help("把全部录屏移到废纸篓，可恢复")
                }
            }

            if recordings.isEmpty {
                RecordLibraryEmptyState(
                    title: "还没有录屏",
                    detail: "开始一次录制，完成后可以在这里继续剪辑或分享。",
                    systemImage: "video.circle",
                    actionTitle: "开始录屏",
                    action: beginRecording
                )
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 250, maximum: 340), spacing: 20),
                        count: 3
                    ),
                    spacing: 22
                ) {
                    ForEach(recordings) { record in
                        videoTile(record)
                    }
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

    @ViewBuilder
    private func videoTile(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                VideoEditorWindowController.shared.open(url: HistoryStore.shared.urlForRecord(record))
            } label: {
                ZStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .underPageBackgroundColor))

                        if let thumb = thumbnails[record.id.uuidString] {
                            GeometryReader { proxy in
                                Image(nsImage: thumb)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                                    .clipped()
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .onAppear { loadThumbnail(for: record) }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipped()

                    Circle()
                        .fill(.black.opacity(0.72))
                        .frame(width: 46, height: 46)
                        .overlay {
                            Image(systemName: "play.fill")
                                .font(RuneFont.swiftUI(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("播放并编辑 \(record.filename)")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.filename)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(record.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 0)

                RecordActionButton(
                    title: copiedRecordID == record.id ? "已复制" : "复制文件到剪贴板",
                    systemImage: copiedRecordID == record.id ? "checkmark" : "doc.on.doc",
                    isActive: copiedRecordID == record.id
                ) {
                    copyRecordToPasteboard(record)
                    markCopied(record)
                }

                Menu {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            HistoryStore.shared.displayURLForRecord(record),
                        ])
                    } label: {
                        Label("在访达中显示", systemImage: "folder")
                    }

                    Divider()

                    Button(role: .destructive) {
                        thumbnails.removeValue(forKey: record.id.uuidString)
                        HistoryStore.shared.deleteRecord(record)
                    } label: {
                        Label("移到废纸篓", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
                .accessibilityLabel("更多操作")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
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
                HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 520)
            }.value
            if let thumb {
                thumbnails[recordID] = NSImage(
                    cgImage: thumb,
                    size: NSSize(width: thumb.width, height: thumb.height)
                )
            }
        }
    }

    @MainActor
    private func beginRecording() {
        let screen = NSScreen.main
        SettingsWindowController.shared.close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            do {
                let started = try await ScreenRecordingManager.shared.startRecording(on: screen)
                if started {
                    RecordingStatusBarController.shared.show(on: screen)
                }
            } catch {
                ToastWindow.shared.show(
                    title: "录屏没有开始",
                    message: error.localizedDescription,
                    systemIcon: "exclamationmark.triangle",
                    on: screen
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
            VStack(spacing: 10) {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                }

                Text("Rune")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("版本 \(version)（\(build)）")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Text("macOS 截图与录屏工具")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            ProofSection("软件更新") {
                SettingsRow("自动检查更新") {
                    Toggle("自动检查更新", isOn: $automaticallyChecksForUpdates)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                HStack(spacing: 10) {
                    Button(updateState.isChecking ? "正在检查…" : "检查更新") {
                        checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(updateState.isChecking)

                    updateStatusView
                }
                .padding(.vertical, 12)

                ProofFootnote("每天最多自动提示一次；检查时只读取版本号，不上传截图或使用数据。")
                    .padding(.bottom, 10)
            }

            ProofSection("来源与许可") {
                licenseRow(
                    title: "BetterShot",
                    detail: "Rune 基于该开源项目独立改造",
                    license: "BSD-3-Clause"
                )
                licenseRow(
                    title: "Space Grotesk · Space Mono",
                    detail: "随安装包保留的备用开源字体资源",
                    license: "SIL OFL 1.1"
                )

                ProofFootnote("完整版权和字体协议保留在安装包的 LICENSE 与 Fonts 目录中。")
                    .padding(.vertical, 10)
            }
        }
    }

    private func licenseRow(title: String, detail: String, license: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(license)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .frame(minHeight: 50)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle, .checking:
            EmptyView()
        case let .upToDate(latestVersion):
            Label("已是最新版 \(latestVersion)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .font(.caption)
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
    case failed(message: String)

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}
