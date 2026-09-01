import SwiftUI
import Carbon
import ServiceManagement

private enum SettingsPreviewSample {
    static let assetID = "mac-7"
}

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
        ZStack {
            RuneAmbientBackdrop()

            HStack(spacing: 0) {
                SettingsSidebar(selection: navigationModel.selection) { section in
                    navigationModel.selection = section
                }
                .frame(width: 184)

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
                .tint(RuneTheme.textPrimary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 1040, minHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Navigation

private struct SettingsSidebar: View {
    let selection: SettingsSection
    let onSelect: (SettingsSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RuneBrandIcon(size: 34)
                Text("Rune")
                    .font(RuneFont.swiftUI(size: 15, weight: .semibold))
                    .foregroundStyle(RuneTheme.textPrimary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 52)
            .padding(.bottom, 28)

            VStack(spacing: 5) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: section == selection
                    ) {
                        onSelect(section)
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("本地优先")
                    .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textSecondary)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                    .font(RuneFont.mono(size: 9, weight: .medium))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.16))
        .overlay(alignment: .trailing) {
            RuneTheme.verticalHairline
        }
    }
}

/// 侧栏条目：选中是一条墨线，不是一块填充。
private struct SettingsSidebarRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 11) {
                RuneGlyph(systemImage: section.icon, isActive: isSelected, size: 14)
                    .frame(width: 20)

                Text(section.rawValue)
                    .font(RuneFont.swiftUI(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? RuneTheme.textPrimary : RuneTheme.textSecondary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.white.opacity(0.052)
                            : (isHovered ? Color.white.opacity(0.035) : Color.clear)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.white.opacity(0.13) : Color.clear,
                        lineWidth: 0.7
                    )
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(RuneTheme.spectralGradient)
                        .frame(width: 1.5, height: 22)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(section.toolbarHelp)
        .accessibilityLabel(section.rawValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - 页面骨架

/// 校样页眉：等宽节戳 + RuneFont 标题。窗口标题栏不显示文字，节名只在这里说一次。
private struct SettingsPageHeader: View {
    let stamp: String?
    let title: String
    let subtitle: String

    init(stamp: String? = nil, title: String, subtitle: String) {
        self.stamp = stamp
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let stamp {
                Text(stamp)
                    .font(RuneFont.mono(size: 10, weight: .medium))
                    .foregroundStyle(RuneTheme.textMuted)
            }

            Text(title)
                .font(RuneFont.swiftUI(size: 19, weight: .semibold))
                .foregroundStyle(RuneTheme.textPrimary)

            Text(subtitle)
                .font(RuneFont.swiftUI(size: 12))
                .foregroundStyle(RuneTheme.textSecondary)
        }
        .textSelection(.enabled)
        .padding(.bottom, 6)
    }
}

/// 分区卡：等宽盖印小标做卡头，卡身浮面 + 1pt 细边。裁切角线不再挂在卡上——
/// 在卡片尺度上它们读作乱码；签名角线只留给素材库悬停与确认画布。
private struct ProofSection<Content: View>: View {
    let title: String
    var isProof = false
    @ViewBuilder let content: () -> Content

    init(_ title: String, isProof: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isProof = isProof
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(RuneFont.mono(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            cardBody
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isProof {
                RuneGlassBackground(
                    cornerRadius: RuneTheme.cardCorner,
                    tint: RuneTheme.glassTint,
                    elevation: .embedded
                )
            } else {
                RuneCardBackground()
            }
        }
    }
}

private struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                content()
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct SettingsStageLayout<Content: View, Stage: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content
    @ViewBuilder let stage: () -> Stage

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder stage: @escaping () -> Stage
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.stage = stage
    }

    var body: some View {
        GeometryReader { proxy in
            let stageWidth = min(336, max(316, proxy.size.width * 0.34))

            HStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title)
                                .font(RuneFont.swiftUI(size: 24, weight: .semibold))
                                .foregroundStyle(RuneTheme.textPrimary)
                            Text(subtitle)
                                .font(RuneFont.swiftUI(size: 11.5))
                                .foregroundStyle(RuneTheme.textSecondary)
                        }
                        .textSelection(.enabled)

                        content()
                    }
                    .frame(maxWidth: 650, alignment: .leading)
                    .padding(.horizontal, 34)
                    .padding(.top, 42)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .top)
                }

                stage()
                    .frame(width: stageWidth)
                    .padding(.trailing, 24)
                    .padding(.vertical, 20)
            }
        }
    }
}

private struct SettingsSectionGroup<Content: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        detail: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)

                if let detail {
                    Text(detail)
                        .font(RuneFont.swiftUI(size: 10.5))
                        .foregroundStyle(RuneTheme.textMuted)
                }
            }

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(RuneTheme.graphite.opacity(0.58))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(RuneTheme.separator, lineWidth: 1)
            )
        }
    }
}

private struct SettingsLine<Control: View>: View {
    let icon: String
    let title: String
    let detail: String
    var showsDivider = true
    @ViewBuilder let control: () -> Control

    init(
        icon: String,
        title: String,
        detail: String,
        showsDivider: Bool = true,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.showsDivider = showsDivider
        self.control = control
    }

    var body: some View {
        HStack(spacing: 13) {
            RuneGlyph(systemImage: icon, size: 15)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RuneFont.swiftUI(size: 12.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                Text(detail)
                    .font(RuneFont.swiftUI(size: 10.5))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 18)
            control()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(RuneTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, 51)
            }
        }
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
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 42)
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
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(RuneFont.mono(size: 10, weight: .medium))
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
            .font(RuneFont.swiftUI(size: 11))
            .foregroundStyle(.secondary)
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
        Button(role: isDestructive ? .destructive : nil, action: action) {
            if isDestructive {
                Text(title)
                    .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                    .foregroundStyle(RuneTheme.signal)
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                            .fill(RuneTheme.graphiteRaised)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                            .strokeBorder(RuneTheme.signal.opacity(0.34), lineWidth: 0.7)
                    )
            } else {
                RuneTheme.secondaryButtonLabel(title)
            }
        }
        .buttonStyle(RuneTheme.RunePressStyle())
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
            if isDestructive {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(RuneTheme.signal)
                    .frame(width: 28, height: 28)
            } else {
                RuneOpticalIconPlate(
                    systemImage: systemImage,
                    isActive: isActive,
                    size: 28
                )
                .opacity(isHovered || isActive ? 1 : 0.76)
            }
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
            RuneOpticalIconPlate(systemImage: systemImage, size: 54)

            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: action) {
                RuneTheme.primaryButtonLabel(actionTitle)
            }
            .buttonStyle(RuneTheme.RunePressStyle())
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

    @State private var defaultConfig: BeautifierConfig
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?

    init() {
        #if DEBUG
        let isVisualAudit = ProcessInfo.processInfo.arguments.contains("--audit-settings=general")
        let initialConfig: BeautifierConfig
        if isVisualAudit {
            var auditConfig = BeautifierConfig.default
            let slate = SolidColor.presets.first { $0.id == "slate" } ?? SolidColor.presets[0]
            auditConfig.style = .solid(slate)
            initialConfig = auditConfig
        } else {
            initialConfig = AppPreferences.defaultBeautifierConfig
        }
        #else
        let initialConfig = AppPreferences.defaultBeautifierConfig
        #endif
        _defaultConfig = State(initialValue: initialConfig)
    }

    private var saveDirDisplayName: String {
        let url = URL(fileURLWithPath: saveDir)
        return url.lastPathComponent
    }

    var body: some View {
        SettingsStageLayout(
            title: "通用",
            subtitle: "管理文件、日常行为与默认截图外观。"
        ) {
            SettingsSectionGroup("文件") {
                        SettingsLine(
                            icon: "folder",
                            title: "保存位置",
                            detail: "截图和录屏文件保存的位置。"
                        ) {
                            Button(action: chooseSaveDirectory) {
                                SettingsControlPlate(
                                    icon: "folder",
                                    text: saveDirDisplayName,
                                    showsChevron: true
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("选择保存位置，当前为\(saveDirDisplayName)")
                        }

                        SettingsLine(
                            icon: "doc",
                            title: "导出格式",
                            detail: "选择截图默认使用的文件类型。"
                        ) {
                            exportFormatMenu
                        }

                        if exportFormatRaw == ExportFormat.jpeg.rawValue {
                            SettingsJPEGQualityRow(quality: $exportQuality)
                        }

                        SettingsLine(
                            icon: "doc.text",
                            title: "文件命名",
                            detail: "设置保存文件的命名方式。",
                            showsDivider: false
                        ) {
                            fileNameMenu
                        }
            }

            SettingsSectionGroup("行为") {
                        SettingsLine(
                            icon: "doc.on.clipboard",
                            title: "保存后复制",
                            detail: "保存完成后自动复制到剪贴板。"
                        ) {
                            Toggle("保存后复制", isOn: $copyAfterSave)
                                .toggleStyle(.runeGlass)
                                .labelsHidden()
                                .accessibilityLabel("保存后复制")
                        }

                        SettingsLine(
                            icon: "speaker.wave.2",
                            title: "快门声音",
                            detail: "截图完成时播放轻提示音。"
                        ) {
                            Toggle("快门声音", isOn: $playSound)
                                .toggleStyle(.runeGlass)
                                .labelsHidden()
                                .accessibilityLabel("快门声音")
                        }

                        SettingsLine(
                            icon: "power",
                            title: "登录时启动",
                            detail: "登录 Mac 后自动打开 Rune。",
                            showsDivider: launchAtLoginError != nil
                        ) {
                            Toggle(
                                "登录时启动",
                                isOn: Binding(
                                    get: { launchAtLogin },
                                    set: { updateLaunchAtLogin(enabled: $0) }
                                )
                            )
                            .toggleStyle(.runeGlass)
                            .labelsHidden()
                            .accessibilityLabel("登录时启动")
                        }

                        if let launchAtLoginError {
                            Text(launchAtLoginError)
                                .font(RuneFont.swiftUI(size: 10.5))
                                .foregroundStyle(RuneTheme.signal)
                                .padding(.horizontal, 51)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
            }

            SettingsSectionGroup("快捷键") {
                        SettingsLine(
                            icon: "keyboard",
                            title: "截图快捷键",
                            detail: "唤起 Rune 的主要截图入口。",
                            showsDivider: false
                        ) {
                            SettingsShortcutPlate(action: .main)
                        }
            }
        } stage: {
            GeneralSettingsPreview(config: $defaultConfig)
        }
        .onChange(of: defaultConfig) { _, newValue in
            AppPreferences.defaultBeautifierConfig = newValue
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
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

    private var exportFormatMenu: some View {
        RuneMenu(menuWidth: 156, entries: {
            ExportFormat.allCases.map { format in
                .item(
                    RuneMenuItem(
                        format.rawValue.uppercased(),
                        isSelected: format.rawValue == exportFormatRaw
                    ) {
                        exportFormatRaw = format.rawValue
                    }
                )
            }
        }) {
            SettingsControlPlate(
                text: exportFormatRaw.uppercased(),
                showsChevron: true
            )
        }
        .accessibilityLabel("导出格式，当前为\(exportFormatRaw.uppercased())")
    }

    private var fileNameMenu: some View {
        RuneMenu(menuWidth: 190, entries: {
            FileNameFormat.allCases.map { format in
                .item(
                    RuneMenuItem(
                        format.label,
                        isSelected: format.rawValue == fileNameFormatRaw
                    ) {
                        fileNameFormatRaw = format.rawValue
                    }
                )
            }
        }) {
            SettingsControlPlate(
                text: fileNameLabel,
                showsChevron: true
            )
        }
        .accessibilityLabel("文件命名方式")
    }

    private var fileNameLabel: String {
        (FileNameFormat(rawValue: fileNameFormatRaw) ?? .systemStyle).label
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginError = error.localizedDescription
        }
    }

}

private struct SettingsControlPlate: View {
    var icon: String? = nil
    let text: String
    var showsChevron = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(RuneFont.swiftUI(size: 12, weight: .regular))
            }

            Text(text)
                .font(RuneFont.swiftUI(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    .foregroundStyle(RuneTheme.textSecondary)
            }
        }
        .foregroundStyle(RuneTheme.textPrimary)
        .padding(.horizontal, 12)
        .frame(minWidth: 108, maxWidth: 156)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(RuneTheme.graphite.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(RuneTheme.separator.opacity(1.25), lineWidth: 1)
        )
        .overlay(RuneSpectralBorder(cornerRadius: 6, lineWidth: 0.5).opacity(0.18))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SettingsJPEGQualityRow: View {
    @Binding var quality: Double

    var body: some View {
        HStack(spacing: 12) {
            Text("JPEG 质量")
                .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)
            Spacer()
            RuneGlassSlider(
                value: $quality,
                in: 0.1...1.0,
                step: 0.05,
                accessibilityLabel: "JPEG 质量",
                accessibilityValue: "\(Int(quality * 100))%"
            )
                .frame(width: 132)
            Text("\(Int(quality * 100))%")
                .font(RuneFont.mono(size: 10, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.leading, 62)
        .frame(height: 46)
        .overlay(alignment: .bottom) {
            Rectangle().fill(RuneTheme.separator).frame(height: 1)
        }
    }
}

private struct SettingsShortcutPlate: View {
    let action: ShortcutService.Action

    @State private var shortcut: ShortcutService.Shortcut?
    @State private var isRecording = false

    var body: some View {
        Group {
            if isRecording {
                ShortcutRecorderView { keyCode, modifiers in
                    shortcut = ShortcutService.Shortcut(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        enabled: true
                    )
                    if let shortcut {
                        ShortcutService.shared.saveShortcut(shortcut, for: action)
                        ShortcutService.shared.registerAll()
                    }
                    isRecording = false
                } onCancel: {
                    isRecording = false
                }
                .frame(width: 128, height: 34)
            } else {
                Button {
                    isRecording = true
                } label: {
                    Text(shortcutDisplayString)
                        .font(RuneFont.mono(size: 13, weight: .medium))
                        .foregroundStyle(RuneTheme.textPrimary)
                        .frame(minWidth: 92)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(RuneTheme.graphite.opacity(0.88))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(RuneTheme.separator.opacity(1.25), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("点击后录入新的快捷键")
                .accessibilityLabel("截图快捷键，当前为\(shortcutDisplayString)")
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
        guard let shortcut else { return "" }
        return ShortcutService.displayString(for: shortcut)
    }
}

private struct GeneralSettingsPreview: View {
    @Binding var config: BeautifierConfig

    var body: some View {
        RuneGlassStage(
            title: "截图外观",
            subtitle: "调整即刻保存"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                DefaultConfigPreview(config: config)
                    .frame(height: 198)
                    .padding(.horizontal, 2)
                    .padding(.top, 18)

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

                VStack(spacing: 14) {
                    InlineAppearanceSlider(
                        label: "边距",
                        value: $config.padding,
                        range: 0.0...0.45,
                        display: "\(Int(config.padding * 100))%"
                    )
                    InlineAppearanceSlider(
                        label: "圆角",
                        value: $config.cornerRadius,
                        range: 0.0...0.12,
                        display: "\(Int(config.cornerRadius * 1000))"
                    )
                    InlineAppearanceSlider(
                        label: "阴影",
                        value: $config.shadowStrength,
                        range: 0.0...1.0,
                        display: "\(Int(config.shadowStrength * 100))%"
                    )
                }
                .padding(.vertical, 14)

                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("背景")
                            .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                            .foregroundStyle(RuneTheme.textPrimary)

                        Spacer()

                        Text(backgroundName)
                            .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                            .foregroundStyle(RuneTheme.textSecondary)
                            .lineLimit(1)
                    }

                    InlineBackgroundPicker(selectedStyle: $config.style)
                }
                .padding(.top, 14)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var backgroundName: String {
        switch config.style {
        case .none:
            return "透明"
        case let .solid(color):
            return color.name
        case let .gradient(preset):
            return preset.name
        case .wallpaper:
            return "自定义图片"
        case .bundledImage:
            return "内置图片"
        }
    }
}

private struct InlineAppearanceSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let display: String

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textSecondary)

                Spacer()

                Text(display)
                    .font(RuneFont.mono(size: 10, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
            }

            RuneGlassSlider(
                value: $value,
                in: range,
                accessibilityLabel: label,
                accessibilityValue: display
            )
        }
    }
}

private struct InlineBackgroundPicker: View {
    @Binding var selectedStyle: BackgroundStyle

    var body: some View {
        VStack(spacing: 10) {
            AppearanceSwatchGrid("颜色") {
                noneButton

                ForEach(SolidColor.presets) { color in
                    solidButton(color)
                }
            }

            AppearanceSwatchGrid("渐变") {
                ForEach(GradientPreset.presets) { preset in
                    gradientButton(preset)
                }
            }

            AppearanceSwatchGrid("图片") {
                ForEach(BundledBackgrounds.macAssets) { asset in
                    bundledImageButton(asset)
                }

                customImageButton
            }
        }
    }

    private var noneButton: some View {
        Button {
            selectedStyle = .none
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                Path { path in
                    path.move(to: CGPoint(x: 18, y: 2))
                    path.addLine(to: CGPoint(x: 2, y: 18))
                }
                .stroke(RuneTheme.signal.opacity(0.75), lineWidth: 1.25)
            }
            .frame(width: 20, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(selectionStroke(isSelected: selectedStyle == .none), lineWidth: selectionWidth(isSelected: selectedStyle == .none))
            )
            .padding(1)
        }
        .buttonStyle(.plain)
        .help("透明背景")
        .accessibilityLabel("透明背景")
    }

    private func solidButton(_ color: SolidColor) -> some View {
        let isSelected: Bool = {
            if case .solid(let c) = selectedStyle { return c.id == color.id }
            return false
        }()

        return Button {
            selectedStyle = .solid(color)
        } label: {
            Circle()
                .fill(color.color)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .strokeBorder(selectionStroke(isSelected: isSelected), lineWidth: selectionWidth(isSelected: isSelected))
                )
                .padding(1)
        }
        .buttonStyle(.plain)
        .help(color.name)
        .accessibilityLabel("纯色，\(color.name)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
                .frame(width: 30, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(selectionStroke(isSelected: isSelected), lineWidth: selectionWidth(isSelected: isSelected))
                )
                .padding(1)
        }
        .buttonStyle(.plain)
        .help(preset.name)
        .accessibilityLabel("渐变，\(preset.name)")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
            .frame(width: 30, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selectionStroke(isSelected: isSelected), lineWidth: selectionWidth(isSelected: isSelected))
            )
            .padding(1)
        }
        .buttonStyle(.plain)
        .help("内置背景图片")
        .accessibilityLabel("内置背景图片")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private var customImageButton: some View {
        let isSelected: Bool = {
            if case .wallpaper = selectedStyle { return true }
            return false
        }()

        return Button { pickCustomImage() } label: {
            Group {
                if case let .wallpaper(source) = selectedStyle,
                   let image = NSImage(contentsOfFile: source.path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                        Image(systemName: "plus")
                            .font(RuneFont.swiftUI(size: 9, weight: .medium))
                            .foregroundStyle(RuneTheme.textSecondary)
                    }
                }
            }
            .frame(width: 30, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(selectionStroke(isSelected: isSelected), lineWidth: selectionWidth(isSelected: isSelected))
            )
            .padding(1)
        }
        .buttonStyle(.plain)
        .help(isSelected ? "更换自定义背景" : "选择自定义背景")
        .accessibilityLabel(isSelected ? "更换自定义背景" : "选择自定义背景")
        .accessibilityValue(isSelected ? "已选择" : "未选择")
    }

    private func selectionStroke(isSelected: Bool) -> Color {
        isSelected ? RuneTheme.textPrimary.opacity(0.95) : Color.white.opacity(0.16)
    }

    private func selectionWidth(isSelected: Bool) -> CGFloat {
        isSelected ? 1.5 : 0.5
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

private struct AppearanceSwatchGrid<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 6),
        count: 8
    )

    init(
        _ label: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                .foregroundStyle(RuneTheme.textMuted)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                content()
            }
        }
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

            let imgW = mockImageW / canvasW * fitted.width
            let imgH = mockImageH / canvasH * fitted.height

            let cornerRadius = config.cornerRadius * shortEdge * min(fitted.width / canvasW, fitted.height / canvasH)
            let m = ImageAlignment.center.cornerMultipliers

            let previewFrame = RoundedRectangle(cornerRadius: 6, style: .continuous)

            ZStack {
                previewBackground(config.style)

                mockScreenshot
                    .frame(width: imgW, height: imgH)
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
            }
            .frame(width: fitted.width, height: fitted.height)
            .clipShape(previewFrame)
            .overlay(previewFrame.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6))
            .position(x: fitted.midX, y: fitted.midY)
        }
    }

    private var mockScreenshot: some View {
        ZStack {
            if let image = BundledBackgrounds.asset(byID: SettingsPreviewSample.assetID)?.image {
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
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Circle().fill(Color.white.opacity(0.22)).frame(width: 6, height: 6)
                Circle().fill(Color.white.opacity(0.14)).frame(width: 6, height: 6)
                Circle().fill(Color.white.opacity(0.10)).frame(width: 6, height: 6)

                Spacer()

                Text("截图完成 · 桌面预览")
                    .font(RuneFont.mono(size: 8.5, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RuneTheme.chromeElevated)

            GeometryReader { proxy in
                let cardWidth = min(206, proxy.size.width - 28)

                ZStack(alignment: overlayPosition == .bottomRight ? .bottomTrailing : .bottomLeading) {
                    Group {
                        if let image = BundledBackgrounds.asset(byID: SettingsPreviewSample.assetID)?.image {
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
                        Label("\(timer.label) 后截图", systemImage: "timer")
                            .font(RuneFont.swiftUI(size: 9.5, weight: .semibold))
                            .foregroundStyle(RuneTheme.chromeText)
                            .padding(.horizontal, 9)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                                    .fill(RuneTheme.chromeBase.opacity(0.90))
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(12)
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
                        .padding(.horizontal, 10)
                        .frame(height: 32)

                        Group {
                            if let image = BundledBackgrounds.asset(byID: SettingsPreviewSample.assetID)?.image {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                RuneTheme.chromeBase
                            }
                        }
                        .frame(width: cardWidth - 20, height: 92)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        HStack(spacing: 9) {
                            Label("复制", systemImage: "doc.on.doc")
                                .font(RuneFont.swiftUI(size: 9, weight: .medium))
                                .foregroundStyle(RuneTheme.primaryOnFill)
                                .padding(.horizontal, 10)
                                .frame(height: 25)
                                .background(
                                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                                        .fill(RuneTheme.primaryFill)
                                )

                            Spacer(minLength: 0)

                            Image(systemName: "pin")
                            Image(systemName: "pencil")
                        }
                        .font(RuneFont.swiftUI(size: 9, weight: .semibold))
                        .foregroundStyle(RuneTheme.chromeMuted)
                        .padding(.horizontal, 10)
                        .frame(height: 39)
                    }
                    .frame(width: cardWidth)
                    .background(RuneTheme.chromeElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(RuneTheme.chromeLine, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.20), radius: 10, y: 5)
                    .padding(14)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsPreviewStatusRow: View {
    let systemImage: String
    let title: String
    let value: String
    var valueColor: Color = RuneTheme.textPrimary
    var showsDivider = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(RuneFont.swiftUI(size: 11, weight: .medium))
                .foregroundStyle(RuneTheme.textMuted)
                .frame(width: 18)

            Text(title)
                .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)

            Spacer(minLength: 10)

            Text(value)
                .font(RuneFont.mono(size: 10, weight: .medium))
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
            }
        }
    }
}

private struct SettingsPreviewFlow: View {
    let steps: [String]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Text(step)
                    .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                    .foregroundStyle(index == 1 ? RuneTheme.textPrimary : RuneTheme.textMuted)
                    .lineLimit(1)

                if index < steps.count - 1 {
                    Image(systemName: "chevron.right")
                        .font(RuneFont.swiftUI(size: 7.5, weight: .semibold))
                        .foregroundStyle(RuneTheme.textMuted.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
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
        SettingsStageLayout(
            title: "截图",
            subtitle: "设置截图发生前后的行为，以及常用快捷键。"
        ) {
            SettingsSectionGroup("截图流程") {
                    SettingsLine(
                        icon: "timer",
                        title: "启动延时",
                        detail: "从按下截图快捷键后开始计算。"
                    ) {
                        RuneOpticalSegmentedPicker(
                            options: SelfTimerDelay.allCases.map { ($0, $0.label) },
                            selection: selfTimerDelay,
                            accessibilityLabel: "启动延时"
                        )
                        .frame(width: 208)
                    }

                    SettingsLine(
                        icon: "rectangle.inset.bottomright.filled",
                        title: "预览位置",
                        detail: "截图完成后悬浮预览出现的位置。"
                    ) {
                        overlayPositionMenu
                    }

                    SettingsLine(
                        icon: "clock",
                        title: "停留时间",
                        detail: "预览自动收起前保留多久。",
                        showsDivider: false
                    ) {
                        HStack(spacing: 10) {
                            RuneGlassSlider(
                                value: $overlayDismissDelay,
                                in: 2...15,
                                step: 1,
                                accessibilityLabel: "预览停留时间",
                                accessibilityValue: "\(Int(overlayDismissDelay)) 秒"
                            )
                            .frame(width: 126)

                            Text("\(Int(overlayDismissDelay)) 秒")
                                .font(RuneFont.mono(size: 9.5, weight: .medium))
                                .foregroundStyle(RuneTheme.textSecondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
            }

            SettingsSectionGroup("智能识别") {
                SettingsLine(
                    icon: "viewfinder.rectangular",
                    title: "识别窗口内部区域",
                    detail: "自动识别弹窗、卡片和窗内面板。",
                    showsDivider: detectUIElements
                ) {
                    Toggle("识别窗口内部区域", isOn: $detectUIElements)
                        .toggleStyle(.runeGlass)
                        .labelsHidden()
                        .accessibilityLabel("识别窗口内部区域")
                }

                if detectUIElements {
                    HStack(spacing: 10) {
                        Image(systemName: accessibilityGranted ? "checkmark.circle.fill" : "lock.open")
                            .foregroundStyle(accessibilityGranted ? RuneTheme.cyan : RuneTheme.textSecondary)
                        Text(accessibilityGranted ? "辅助功能权限已允许" : "需要一次辅助功能权限")
                            .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                            .foregroundStyle(RuneTheme.textSecondary)
                        Spacer()
                        if !accessibilityGranted {
                            Button {
                                UIElementDetector.requestAccess()
                            } label: {
                                RuneTheme.compactButtonLabel("前往允许", emphasized: true)
                            }
                            .buttonStyle(RuneTheme.RunePressStyle())
                        }
                    }
                    .padding(.horizontal, 51)
                    .padding(.vertical, 11)
                }
            }

            SettingsSectionGroup("快捷键", detail: "点击按键组合即可重新录入") {
                VStack(spacing: 0) {
                    ShortcutRow(label: "全局截图", action: .main)
                    ShortcutRow(label: "连拍", action: .burst)
                    ShortcutRow(label: "录屏", action: .recording)
                    ShortcutRow(label: "取色", action: .colorPicker)
                }
                .padding(.horizontal, 16)
                .id(shortcutResetID)

                HStack {
                    Spacer()
                    ResetButton("恢复默认快捷键") {
                        restoreDefaultShortcuts()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            HStack {
                Spacer()
                ResetButton("恢复全部截图设置") {
                    confirmsReset = true
                }
            }
        } stage: {
            RuneGlassStage(
                title: "完成后的预览",
                subtitle: "截图保存后会这样出现"
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    CaptureResultPreview(
                        timer: selfTimerDelay.wrappedValue,
                        overlayPosition: overlayPosition.wrappedValue,
                        dismissDelay: overlayDismissDelay
                    )
                    .frame(height: 300)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.top, 22)

                    VStack(spacing: 0) {
                        SettingsPreviewStatusRow(
                            systemImage: "timer",
                            title: "开始截图",
                            value: selfTimerDelay.wrappedValue == .off
                                ? "立即"
                                : selfTimerDelay.wrappedValue.label
                        )
                        SettingsPreviewStatusRow(
                            systemImage: "rectangle.inset.bottomright.filled",
                            title: "悬浮位置",
                            value: overlayPosition.wrappedValue == .bottomRight
                                ? "右下角"
                                : "左下角"
                        )
                        SettingsPreviewStatusRow(
                            systemImage: "clock",
                            title: "自动收起",
                            value: "\(Int(overlayDismissDelay)) 秒",
                            valueColor: RuneTheme.cyan,
                            showsDivider: false
                        )
                    }
                    .padding(.top, 12)

                    Spacer(minLength: 18)

                    SettingsPreviewFlow(
                        steps: ["完成截图", "悬浮操作", "自动收起"]
                    )
                }
                .frame(maxHeight: .infinity)
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

    private var overlayPositionMenu: some View {
        RuneMenu(menuWidth: 132, entries: {
            [
                .item(
                    RuneMenuItem(
                        "右下角",
                        isSelected: overlayPosition.wrappedValue == .bottomRight
                    ) {
                        overlayPositionRaw = OverlayPosition.bottomRight.rawValue
                    }
                ),
                .item(
                    RuneMenuItem(
                        "左下角",
                        isSelected: overlayPosition.wrappedValue == .bottomLeft
                    ) {
                        overlayPositionRaw = OverlayPosition.bottomLeft.rawValue
                    }
                ),
            ]
        }) {
            SettingsControlPlate(
                text: overlayPosition.wrappedValue == .bottomRight ? "右下角" : "左下角",
                showsChevron: true
            )
        }
        .accessibilityLabel("预览位置")
    }
}

// MARK: - Recording Settings

private struct RecordingResultPreview: View {
    let fps: Int
    let showCursor: Bool
    let captureAudio: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(RuneTheme.signal)
                    .frame(width: 7, height: 7)
                Text("正在录制")
                    .font(RuneFont.swiftUI(size: 9.5, weight: .semibold))
                    .foregroundStyle(RuneTheme.chromeText)

                Spacer()

                Text("00:08")
                    .font(RuneFont.mono(size: 9.5, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RuneTheme.chromeElevated)

            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Group {
                        if let image = BundledBackgrounds.asset(byID: SettingsPreviewSample.assetID)?.image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            RuneTheme.paperControl
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                    HStack(spacing: 8) {
                        Circle()
                            .fill(RuneTheme.signal)
                            .frame(width: 7, height: 7)

                        Text("REC")
                            .font(RuneFont.mono(size: 9.5, weight: .semibold))
                            .foregroundStyle(RuneTheme.chromeText)

                        Spacer()

                        Text("\(fps) FPS")
                            .font(RuneFont.mono(size: 8.5, weight: .medium))
                            .foregroundStyle(RuneTheme.chromeMuted)
                            .lineLimit(1)

                        Image(systemName: captureAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .accessibilityLabel(captureAudio ? "录制系统声音" : "不录制系统声音")

                        Image(systemName: showCursor ? "cursorarrow" : "cursorarrow.slash")
                            .accessibilityLabel(showCursor ? "录制鼠标指针" : "不录制鼠标指针")
                    }
                    .font(RuneFont.swiftUI(size: 10, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeText)
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(
                        RuneTheme.chromeBase.opacity(0.92),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .padding(12)

                    if showCursor {
                        Image(systemName: "cursorarrow")
                            .font(RuneFont.swiftUI(size: 25, weight: .medium))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                            .offset(x: 74, y: -82)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct RecordingPreviewTimeline: View {
    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("00:00")
                Spacer()
                Text("00:08")
            }
            .font(RuneFont.mono(size: 8.5, weight: .medium))
            .foregroundStyle(RuneTheme.textMuted)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 3)

                    Capsule()
                        .fill(RuneTheme.cyan.opacity(0.82))
                        .frame(width: proxy.size.width * 0.56, height: 3)

                    Circle()
                        .fill(RuneTheme.textPrimary)
                        .frame(width: 7, height: 7)
                        .offset(x: max(0, proxy.size.width * 0.56 - 3.5))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)
        }
        .padding(.vertical, 12)
    }
}

struct RecordingSettingsTab: View {
    @AppStorage("bs_recordingFPS") private var recordingFPS: Int = 30
    @AppStorage("bs_recordingShowCursor") private var showCursor: Bool = true
    @AppStorage("bs_recordingCaptureAudio") private var captureAudio: Bool = false
    @State private var confirmsReset = false

    var body: some View {
        SettingsStageLayout(
            title: "录屏",
            subtitle: "决定录制画面的流畅度，以及需要包含的内容。"
        ) {
            SettingsSectionGroup("画面") {
                    SettingsLine(
                        icon: "film.stack",
                        title: "帧率",
                        detail: "帧率越高越流畅，生成的文件也会更大。",
                        showsDivider: false
                    ) {
                        RuneOpticalSegmentedPicker(
                            options: [
                                (24, "24 帧/秒"),
                                (30, "30 帧/秒"),
                                (60, "60 帧/秒")
                            ],
                            selection: $recordingFPS,
                            accessibilityLabel: "帧率"
                        )
                        .frame(width: 222)
                    }
            }

            SettingsSectionGroup("录制内容") {
                    SettingsLine(
                        icon: "cursorarrow",
                        title: "鼠标指针",
                        detail: "在视频中保留鼠标移动轨迹。"
                    ) {
                        Toggle("录制鼠标指针", isOn: $showCursor)
                            .toggleStyle(.runeGlass)
                            .labelsHidden()
                            .accessibilityLabel("录制鼠标指针")
                    }
                    SettingsLine(
                        icon: "speaker.wave.2",
                        title: "系统声音",
                        detail: "同时录制应用与系统播放的声音。",
                        showsDivider: false
                    ) {
                        Toggle("录制系统声音", isOn: $captureAudio)
                            .toggleStyle(.runeGlass)
                            .labelsHidden()
                            .accessibilityLabel("录制系统声音")
                    }
            }

            HStack {
                Spacer()
                ResetButton("恢复全部录屏设置") {
                    confirmsReset = true
                }
            }
        } stage: {
            RuneGlassStage(
                title: "录制状态",
                subtitle: "当前设置下的录屏画面"
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    RecordingResultPreview(
                        fps: recordingFPS,
                        showCursor: showCursor,
                        captureAudio: captureAudio
                    )
                    .frame(height: 278)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.top, 22)

                    RecordingPreviewTimeline()

                    VStack(spacing: 0) {
                        SettingsPreviewStatusRow(
                            systemImage: "film.stack",
                            title: "画面流畅度",
                            value: "\(recordingFPS) FPS",
                            valueColor: RuneTheme.cyan
                        )
                        SettingsPreviewStatusRow(
                            systemImage: "cursorarrow",
                            title: "鼠标指针",
                            value: showCursor ? "保留" : "隐藏"
                        )
                        SettingsPreviewStatusRow(
                            systemImage: captureAudio ? "speaker.wave.2" : "speaker.slash",
                            title: "系统声音",
                            value: captureAudio ? "录制" : "关闭",
                            showsDivider: false
                        )
                    }

                    Spacer(minLength: 18)

                    SettingsPreviewFlow(
                        steps: ["开始录制", "实时状态", "完成导出"]
                    )
                }
                .frame(maxHeight: .infinity)
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
    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(label)
                .font(RuneFont.swiftUI(size: 13))
                .foregroundStyle(.primary)

            Spacer()

            if isRecording {
                ShortcutRecorderView { keyCode, modifiers in
                    shortcut = ShortcutService.Shortcut(
                        keyCode: keyCode,
                        modifiers: modifiers,
                        enabled: true
                    )
                    if let s = shortcut {
                        ShortcutService.shared.saveShortcut(s, for: action)
                        ShortcutService.shared.registerAll()
                    }
                    isRecording = false
                } onCancel: {
                    isRecording = false
                }
                .frame(width: 112, height: 28)
            } else {
                // 键帽徽章：等宽字符 + 浮面细边，与工具条上的快捷键提示同一种字
                Button {
                    isRecording = true
                } label: {
                    Text(shortcutDisplayString)
                        .font(RuneFont.mono(size: 11, weight: .medium))
                        .foregroundStyle(RuneTheme.textPrimary)
                        .frame(minWidth: 96)
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isHovered ? RuneTheme.card.opacity(0.95) : RuneTheme.card)
                        )
                        .overlay {
                            if isHovered {
                                RuneSpectralBorder(cornerRadius: 7, lineWidth: 0.7)
                                    .opacity(0.62)
                            } else {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(RuneTheme.separator, lineWidth: 1)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("点击后按下新的组合键")
                .accessibilityLabel("\(label)快捷键：\(shortcutDisplayString)")
            }
        }
        .frame(minHeight: 42)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
        .onAppear {
            var loaded = ShortcutService.shared.loadShortcut(for: action) ?? defaultShortcut
            if !loaded.enabled {
                loaded.enabled = true
                ShortcutService.shared.saveShortcut(loaded, for: action)
                ShortcutService.shared.registerAll()
            }
            shortcut = loaded
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
        guard let s = shortcut else { return "" }
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
    @State private var updateState: UpdateViewState = .idle
    @State private var showsLicenses = false

    private static let repositoryURL = URL(string: "https://github.com/xiixiixixi/rune")!
    private static let releasesURL = URL(string: "https://github.com/xiixiixixi/rune/releases")!

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    var body: some View {
        SettingsStageLayout(
            title: "关于 Rune",
            subtitle: "产品信息、版本与致谢。"
        ) {
            VStack(alignment: .leading, spacing: 13) {
                Text("捕捉、编辑与管理，\n都留在你的 Mac。")
                    .font(RuneFont.swiftUI(size: 22, weight: .semibold))
                    .foregroundStyle(RuneTheme.textPrimary)
                    .lineSpacing(2)

                Text("Rune 是为 macOS 打造的截图与录屏工具。除主动检查新版本外，截图内容不会离开你的设备。")
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .lineSpacing(3)
                    .frame(maxWidth: 430, alignment: .leading)

                Label("本地优先，不上传截图内容", systemImage: "lock.shield")
                    .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .textSelection(.enabled)
            .padding(.top, 4)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 9) {
                Text("继续了解")
                    .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)

                VStack(spacing: 0) {
                    AboutResourceRow(
                        icon: "clock.arrow.circlepath",
                        title: "版本发布",
                        detail: "查看更新记录与历史版本"
                    ) {
                        NSWorkspace.shared.open(Self.releasesURL)
                    }

                    AboutResourceRow(
                        icon: "arrow.triangle.branch",
                        title: "项目主页",
                        detail: "查看源代码、问题与反馈"
                    ) {
                        NSWorkspace.shared.open(Self.repositoryURL)
                    }

                    AboutResourceRow(
                        icon: "book.closed",
                        title: "致谢与许可",
                        detail: "阅读随安装包提供的完整许可原文",
                        showsDivider: false
                    ) {
                        showsLicenses = true
                    }
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(RuneTheme.separator)
                        .frame(height: 1)
                }
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(RuneTheme.separator)
                        .frame(height: 1)
                }
            }
        } stage: {
            RuneGlassStage(
                title: "Rune",
                subtitle: "macOS 截图与录屏"
            ) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)

                    RuneBrandIcon(size: 132)

                    Text("Rune")
                        .font(RuneFont.swiftUI(size: 24, weight: .semibold))
                        .foregroundStyle(RuneTheme.textPrimary)
                        .padding(.top, 16)

                    Text("为 Mac 的每一次捕捉而生")
                        .font(RuneFont.swiftUI(size: 10.5))
                        .foregroundStyle(RuneTheme.textSecondary)
                        .padding(.top, 6)

                    Spacer()

                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 1)

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("版本 \(version)")
                                    .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                                    .foregroundStyle(RuneTheme.textPrimary)
                                Text("build \(build)")
                                    .font(RuneFont.mono(size: 9.5, weight: .medium))
                                    .foregroundStyle(RuneTheme.textMuted)
                            }

                            Spacer(minLength: 8)

                            Button {
                                checkForUpdates()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                                    Text(updateState.isChecking ? "正在检查…" : "检查更新")
                                        .font(RuneFont.swiftUI(size: 11, weight: .medium))
                                }
                                .foregroundStyle(
                                    updateState.isChecking
                                        ? RuneTheme.textMuted
                                        : RuneTheme.textPrimary
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(updateState.isChecking)
                            .accessibilityLabel(updateState.isChecking ? "正在检查更新" : "检查更新")
                            .accessibilityHint("查询 Rune 的最新版本")
                        }

                        updateStatusView
                    }
                    .padding(.vertical, 15)

                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 1)

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自动更新检测")
                                .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                                .foregroundStyle(RuneTheme.textPrimary)
                            Text("启动时检查 · 运行期间每小时检查")
                                .font(RuneFont.swiftUI(size: 9.5))
                                .foregroundStyle(RuneTheme.textMuted)
                        }

                        Spacer(minLength: 8)

                        Label("已开启", systemImage: "checkmark.circle.fill")
                            .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                            .foregroundStyle(RuneTheme.cyan)
                            .accessibilityLabel("自动更新检测已开启")
                    }
                    .padding(.top, 15)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $showsLicenses) {
            RuneLicensesView()
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在查询 Rune 的最新版本")
            }
            .font(RuneFont.swiftUI(size: 9.5))
            .foregroundStyle(RuneTheme.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正在查询 Rune 的最新版本")
        case let .upToDate(latestVersion):
            Label("已是最新版 \(latestVersion)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(RuneTheme.cyan)
                .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(RuneTheme.amber)
                .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
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

private struct AboutResourceRow: View {
    let icon: String
    let title: String
    let detail: String
    var showsDivider = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                RuneGlyph(systemImage: icon, size: 14)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(RuneFont.swiftUI(size: 12.5, weight: .medium))
                        .foregroundStyle(RuneTheme.textPrimary)
                    Text(detail)
                        .font(RuneFont.swiftUI(size: 10.5))
                        .foregroundStyle(RuneTheme.textSecondary)
                }

                Spacer(minLength: 18)

                Image(systemName: "chevron.right")
                    .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .padding(.horizontal, 2)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Rectangle()
                    .fill(RuneTheme.separator)
                    .frame(height: 1)
                    .padding(.leading, 37)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

private struct RuneLicensesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: RuneLicenseDocument = .application

    var body: some View {
        ZStack {
            RuneAmbientBackdrop()

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("致谢与许可")
                            .font(RuneFont.swiftUI(size: 18, weight: .semibold))
                            .foregroundStyle(RuneTheme.textPrimary)
                        Text("随 Rune 安装包提供的完整许可原文")
                            .font(RuneFont.swiftUI(size: 10.5))
                            .foregroundStyle(RuneTheme.textSecondary)
                    }

                    Spacer()

                    Button("完成") {
                        dismiss()
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 24)
                .frame(height: 72)

                Rectangle()
                    .fill(RuneTheme.separator)
                    .frame(height: 1)

                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        ForEach(RuneLicenseDocument.allCases) { document in
                            Button {
                                selection = document
                            } label: {
                                HStack(spacing: 10) {
                                    RuneGlyph(
                                        systemImage: document.icon,
                                        isActive: selection == document,
                                        size: 13
                                    )
                                    .frame(width: 20)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(document.title)
                                            .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                                            .foregroundStyle(RuneTheme.textPrimary)
                                        Text(document.licenseName)
                                            .font(RuneFont.mono(size: 8.5, weight: .medium))
                                            .foregroundStyle(RuneTheme.textMuted)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(
                                            selection == document
                                                ? Color.white.opacity(0.07)
                                                : Color.clear
                                        )
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selection == document ? [.isSelected] : [])
                        }

                        Spacer()
                    }
                    .padding(12)
                    .frame(width: 194)
                    .background(Color.black.opacity(0.14))

                    Rectangle()
                        .fill(RuneTheme.separator)
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selection.title)
                                .font(RuneFont.swiftUI(size: 15, weight: .semibold))
                                .foregroundStyle(RuneTheme.textPrimary)
                            Text(selection.detail)
                                .font(RuneFont.swiftUI(size: 10.5))
                                .foregroundStyle(RuneTheme.textSecondary)
                        }

                        Rectangle()
                            .fill(RuneTheme.separator)
                            .frame(height: 1)

                        ScrollView(showsIndicators: false) {
                            Text(selection.contents)
                                .font(RuneFont.mono(size: 10, weight: .regular))
                                .foregroundStyle(RuneTheme.textSecondary)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .preferredColorScheme(.dark)
        .frame(width: 720, height: 520)
    }
}

private enum RuneLicenseDocument: String, CaseIterable, Identifiable {
    case application
    case spaceMono
    case spaceGrotesk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "应用源码"
        case .spaceMono: return "Space Mono"
        case .spaceGrotesk: return "Space Grotesk"
        }
    }

    var licenseName: String {
        switch self {
        case .application: return "BSD 3-Clause"
        case .spaceMono, .spaceGrotesk: return "SIL OFL 1.1"
        }
    }

    var detail: String {
        switch self {
        case .application: return "Rune 随安装包提供的应用源码许可"
        case .spaceMono: return "Space Mono 字体版权与开放字体许可"
        case .spaceGrotesk: return "Space Grotesk 字体版权与开放字体许可"
        }
    }

    var icon: String {
        switch self {
        case .application: return "chevron.left.forwardslash.chevron.right"
        case .spaceMono, .spaceGrotesk: return "textformat"
        }
    }

    var contents: String {
        let resource: (name: String, extension: String?, subdirectory: String?)
        switch self {
        case .application:
            resource = ("LICENSE", nil, nil)
        case .spaceMono:
            resource = ("OFL", "txt", "Fonts")
        case .spaceGrotesk:
            resource = ("OFL-FONTS", "txt", "Fonts")
        }

        guard let url = Bundle.main.url(
            forResource: resource.name,
            withExtension: resource.extension,
            subdirectory: resource.subdirectory
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "未能读取随安装包提供的许可文件。请确认 Rune 应用资源完整后重试。"
        }
        return text
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
