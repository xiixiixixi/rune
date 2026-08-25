import SwiftUI

// MARK: - Panel Root

struct MenuBarPanelView: View {
    var dismissPopover: @MainActor () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    private let arrowWidth: CGFloat = 22
    private let arrowHeight: CGFloat = 10
    private let panelRadius: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            PopoverArrow()
                .fill(RuneTheme.chromeBase)
                .frame(width: arrowWidth, height: arrowHeight)

            MenuBarContentView(dismissPopover: dismissPopover)
                .background(RuneTheme.chromeBase)
                .clipShape(RoundedRectangle(cornerRadius: panelRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: panelRadius, style: .continuous)
                        .strokeBorder(RuneTheme.chromeLine, lineWidth: 1)
                )
        }
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .offset(y: isVisible || reduceMotion ? 0 : -4)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                isVisible = true
            }
        }
    }
}

private struct PopoverArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 2.5
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - radius, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + radius, y: rect.minY + radius),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Panel Content

struct MenuBarContentView: View {
    var dismissPopover: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 8) {
                TrayFeatureButton(
                    title: "截图",
                    subtitle: "拖选区域或点窗口",
                    icon: "camera.viewfinder",
                    shortcut: ShortcutService.shared.displayString(for: .main),
                    isAccent: true
                ) {
                    dismissAndRun(.main)
                }

                TrayFeatureButton(
                    title: "连拍",
                    subtitle: "连续 · 定数 · 延时",
                    icon: "camera.fill",
                    shortcut: ShortcutService.shared.displayString(for: .burst),
                    isAccent: false
                ) {
                    dismissAndRunBurst(mode: .burst)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            TrayDivider()

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                spacing: 8
            ) {
                TrayActionButton(title: "滚动长图", icon: "arrow.down.doc") {
                    dismissAndRunScrollCapture()
                }

                TrayRecordingMenu(
                    onFullScreen: { startRecordingFromMenu(mode: .fullScreen) },
                    onArea: { startRecordingFromMenu(mode: .area) }
                )

                TrayActionButton(title: "取色", icon: "eyedropper") {
                    dismissAndRun(.colorPicker)
                }

                TrayActionButton(title: "文字识别", icon: "text.viewfinder") {
                    dismissAndRun(.ocr)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            TrayDivider()

            RecentCaptureSection(
                records: Array(HistoryStore.shared.records.prefix(8)),
                onOpen: open,
                onShowAll: { openSettings(section: .history) }
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            if PinnedScreenshotController.shared.hasPinnedWindows {
                TrayDivider()

                HStack(spacing: 10) {
                    Label(
                        "\(PinnedScreenshotController.shared.pinnedCount) 张贴图",
                        systemImage: "pin.fill"
                    )
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                    .foregroundStyle(RuneTheme.chromeText)

                    Spacer()

                    if PinnedScreenshotController.shared.hasPassthroughWindows {
                        Button("恢复交互") {
                            PinnedScreenshotController.shared.restoreInteractions()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RuneTheme.chromeMuted)
                    }

                    Button("全部关闭") {
                        PinnedScreenshotController.shared.unpinAll()
                        dismissPopover()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RuneTheme.chromeMuted)
                }
                .font(RuneFont.swiftUI(size: 11, weight: .medium))
                .padding(.horizontal, 16)
                .frame(height: 48)
            }

            TrayDivider()

            HStack(spacing: 8) {
                Button {
                    openSettings()
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .font(RuneFont.swiftUI(size: 12, weight: .medium))
                        .foregroundStyle(RuneTheme.chromeMuted)
                }
                .buttonStyle(.plain)
                .help("设置 (⌘,)")

                Spacer()

                Text("Rune")
                    .font(RuneFont.mono(size: 9, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeMuted.opacity(0.7))

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(RuneFont.swiftUI(size: 12, weight: .medium))
                        .foregroundStyle(RuneTheme.chromeMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("退出 Rune (⌘Q)")
                .accessibilityLabel("退出 Rune")
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(RuneTheme.chromeLine)
                    .frame(height: 1)
            }
        }
        .frame(width: 560)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Rune")
                .font(RuneFont.swiftUI(size: 16, weight: .bold))
                .foregroundStyle(RuneTheme.chromeText)

            // 数据声部的小章：版本号用 Space Mono，像校样单上的机读行
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(RuneFont.mono(size: 9, weight: .medium))
                .foregroundStyle(RuneTheme.chromeMuted)

            Spacer()

            Text("截图 · 标注 · 贴图")
                .font(RuneFont.mono(size: 9, weight: .medium))
                .foregroundStyle(RuneTheme.chromeMuted)
                .tracking(1.2)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var originScreen: NSScreen? {
        MenuBarPopoverController.shared.originScreen
    }

    private func dismissAndRun(_ action: ShortcutService.Action) {
        nonisolated(unsafe) let screen = originScreen
        dismissPopover()
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            await CaptureOrchestrator.shared.performCapture(action, on: screen)
        }
    }

    private func dismissAndRunBurst(mode: BurstMode) {
        nonisolated(unsafe) let screen = originScreen
        dismissPopover()
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            await BurstCaptureController.shared.prepareAndBegin(presetMode: mode, on: screen)
        }
    }

    private func dismissAndRunScrollCapture() {
        nonisolated(unsafe) let screen = originScreen
        dismissPopover()
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            await ScrollCaptureController.shared.start(on: screen)
        }
    }

    private func startRecordingFromMenu(mode: RecordingMode) {
        nonisolated(unsafe) let screen = originScreen
        dismissPopover()
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            await startRecording(mode: mode, on: screen)
        }
    }

    private func open(_ record: CaptureRecord) {
        let screen = originScreen
        dismissPopover()
        if record.kind == .recording {
            PreviewOverlay.shared.show(url: HistoryStore.shared.displayURLForRecord(record), on: screen)
        } else {
            // 截图记录：直接贴到屏幕右下角当缩略图，常用操作（复制等）在贴图工具条上
            PinnedScreenshotController.shared.pin(
                url: HistoryStore.shared.displayURLForRecord(record),
                on: screen,
                placement: .bottomRight
            )
        }
    }

    private func openSettings(section: SettingsSection? = nil) {
        let screen = originScreen
        dismissPopover()
        SettingsWindowController.shared.open(on: screen, section: section)
    }

    private enum RecordingMode {
        case fullScreen, area
    }

    @MainActor
    private func startRecording(mode: RecordingMode, on screen: NSScreen?) async {
        do {
            let started: Bool
            switch mode {
            case .fullScreen:
                started = try await ScreenRecordingManager.shared.startFullScreenRecording(on: screen)
            case .area:
                started = try await ScreenRecordingManager.shared.startAreaRecording(on: screen)
            }
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

// MARK: - Reusable Controls

private struct TrayFeatureButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let shortcut: String
    let isAccent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon)
                        .font(RuneFont.swiftUI(size: 19, weight: .medium))
                        .foregroundStyle(isAccent ? RuneTheme.paperInk : RuneTheme.chromeText)

                    Spacer()

                    // 快捷键是"机器读数"：主卡上白底墨字，次卡上纸底灰字
                    Text(shortcut)
                        .font(RuneFont.mono(size: 9, weight: .medium))
                        .foregroundStyle(isAccent ? RuneTheme.paperTextSecondary : RuneTheme.chromeMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(isAccent ? RuneTheme.paperControl : RuneTheme.chromeBase)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(RuneFont.swiftUI(size: 14, weight: .bold))
                        .foregroundStyle(isAccent ? RuneTheme.paperInk : RuneTheme.chromeText)
                    Text(subtitle)
                        .font(RuneFont.swiftUI(size: 10))
                        .foregroundStyle(isAccent ? RuneTheme.paperTextSecondary : RuneTheme.chromeMuted)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                    .fill(isAccent ? RuneTheme.paperCard : RuneTheme.chromeElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                    .strokeBorder(
                        isAccent
                            ? RuneTheme.paperSeparator
                            : (isHovered ? RuneTheme.chromeMuted : RuneTheme.chromeLine),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isAccent ? .black.opacity(isHovered ? 0.18 : 0.10) : .clear,
                radius: isHovered ? 14 : 8,
                y: 4
            )
            .contentShape(RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous))
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .onHover { isHovered = $0 }
        .help(title == "连拍" ? "连续、定数或延时拍摄，开始后可暂停或结束" : "拖选区域、点窗口或点桌面截图")
        .accessibilityLabel("\(title)，\(subtitle)，快捷键 \(shortcut)")
    }
}

private struct TrayActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            TrayActionLabel(title: title, icon: icon, isHovered: isHovered)
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

private struct TrayActionLabel: View {
    let title: String
    let icon: String
    var showsChevron = false
    var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(RuneFont.swiftUI(size: 13, weight: .medium))
                .foregroundStyle(RuneTheme.chromeMuted)
                .frame(width: 17)

            Text(title)
                .font(RuneFont.swiftUI(size: 12, weight: .medium))
                .foregroundStyle(RuneTheme.chromeText)

            Spacer(minLength: 2)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(RuneFont.swiftUI(size: 8, weight: .bold))
                    .foregroundStyle(RuneTheme.chromeMuted)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? RuneTheme.chromeLine.opacity(0.82) : RuneTheme.chromeElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isHovered ? RuneTheme.chromeMuted : RuneTheme.chromeLine, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct TrayRecordingMenu: View {
    let onFullScreen: () -> Void
    let onArea: () -> Void

    @State private var isHovered = false

    var body: some View {
        RuneMenu(
            surface: .chrome,
            entries: {
                [
                    .item(RuneMenuItem("全屏录制", systemImage: "desktopcomputer", action: onFullScreen)),
                    .item(RuneMenuItem("区域录制", systemImage: "rectangle.dashed", action: onArea)),
                ]
            }
        ) {
            TrayActionLabel(
                title: "录屏",
                icon: "record.circle",
                showsChevron: true,
                isHovered: isHovered
            )
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .onHover { isHovered = $0 }
        .help("选择全屏或区域录制")
        .accessibilityLabel("录屏，选择全屏或区域")
    }
}

private struct TrayFullWidthButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        TrayActionButton(title: title, icon: icon, action: action)
    }
}

private struct RecentCaptureSection: View {
    let records: [CaptureRecord]
    let onOpen: (CaptureRecord) -> Void
    let onShowAll: () -> Void

    @State private var thumbnails: [UUID: NSImage] = [:]
    @State private var hoveredRecordID: UUID?
    @State private var copiedRecordID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("最近截图")
                        .font(RuneFont.swiftUI(size: 13, weight: .semibold))
                    if !records.isEmpty {
                        Text("\(records.count) 张")
                            .font(RuneFont.mono(size: 10, weight: .medium))
                            .foregroundStyle(RuneTheme.chromeMuted)
                    }
                }
                .foregroundStyle(RuneTheme.chromeText)

                Spacer()

                Button(action: onShowAll) {
                    HStack(spacing: 3) {
                        Text("全部")
                        Image(systemName: "chevron.right")
                            .font(RuneFont.swiftUI(size: 8, weight: .bold))
                    }
                    .font(RuneFont.swiftUI(size: 10, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看全部记录")
            }

            if records.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.stack")
                        .foregroundStyle(RuneTheme.chromeMuted)
                    Text("截图和录屏会出现在这里")
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(RuneTheme.chromeMuted)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 120)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(RuneTheme.chromeElevated)
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(records) { record in
                            recordTile(record)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    /// 单个历史瓦片：整块点击=贴到屏幕右下角；悬停露出"复制"角标（最常用，一步到位）；
    /// 右键收着"编辑 / 在访达中显示"这些不常用操作。
    private func recordTile(_ record: CaptureRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Button {
                    onOpen(record)
                } label: {
                    ZStack {
                        RuneTheme.chromeElevated

                        if let thumbnail = thumbnails[record.id] {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: tileWidth, height: tileImageHeight)
                                .clipped()
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(RuneTheme.chromeMuted)
                        }

                        if record.kind == .recording {
                            Image(systemName: "play.circle.fill")
                                .font(RuneFont.swiftUI(size: 24))
                                .foregroundStyle(.white.opacity(0.92))
                                .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
                        }
                    }
                    .frame(width: tileWidth, height: tileImageHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                hoveredRecordID == record.id ? RuneTheme.chromeText.opacity(0.8) : RuneTheme.chromeLine,
                                lineWidth: 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(RuneTheme.RunePressStyle())
                .help(record.kind == .recording
                      ? "点击预览 · \(record.filename)"
                      : "点击贴到屏幕右下角 · \(record.filename)")
                .contextMenu {
                    Button("复制") {
                        copyRecord(record)
                    }
                    if record.kind == .recording {
                        Button("编辑") {
                            VideoEditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
                        }
                    } else {
                        Button("编辑") {
                            EditorWindowController.shared.open(url: HistoryStore.shared.displayURLForRecord(record))
                        }
                    }
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.displayURLForRecord(record)])
                    }
                }
                .task(id: record.id) {
                    let url = HistoryStore.shared.displayURLForRecord(record)
                    let kind = record.kind
                    let thumbnail = await Task.detached {
                        HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 360)
                    }.value
                    if let thumbnail {
                        thumbnails[record.id] = NSImage(
                            cgImage: thumbnail,
                            size: NSSize(width: thumbnail.width, height: thumbnail.height)
                        )
                    }
                }

                if hoveredRecordID == record.id || copiedRecordID == record.id {
                    Button {
                        copyRecord(record)
                    } label: {
                        Image(systemName: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
                            .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                            .foregroundStyle(RuneTheme.paperInk)
                            .frame(width: 28, height: 28)
                            .background(RuneTheme.paperCard, in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(7)
                    .help("复制到剪贴板")
                    .transition(.opacity.animation(.easeInOut(duration: 0.12)))
                }
            }

            Text(record.createdAt, style: .relative)
                .font(RuneFont.mono(size: 10, weight: .medium))
                .foregroundStyle(RuneTheme.chromeMuted)
                .lineLimit(1)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredRecordID = hovering ? record.id : nil
            }
        }
    }

    private func copyRecord(_ record: CaptureRecord) {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let kind = record.kind
        let recordID = record.id
        Task.detached(priority: .userInitiated) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if kind == .recording {
                pasteboard.writeObjects([url as NSURL])
            } else if let image = NSImage(contentsOf: url) {
                pasteboard.writeObjects([image])
            }
            await MainActor.run {
                copiedRecordID = recordID
                Task {
                    try? await Task.sleep(for: .milliseconds(1200))
                    if copiedRecordID == recordID {
                        copiedRecordID = nil
                    }
                }
            }
        }
    }

    private let tileWidth: CGFloat = 150
    private let tileImageHeight: CGFloat = 154
}

private struct TrayDivider: View {
    var body: some View {
        Rectangle()
            .fill(RuneTheme.chromeLine)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}
