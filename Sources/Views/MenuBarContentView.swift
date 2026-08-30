import AppKit
import SwiftUI

// MARK: - Panel root

struct MenuBarPanelView: View {
    var dismissPopover: @MainActor () -> Void

    var body: some View {
        MenuBarContentView(dismissPopover: dismissPopover)
            .background(RuneCardBackground(cornerRadius: RuneTheme.cardCorner))
            .overlay(
                RoundedRectangle(cornerRadius: RuneTheme.cardCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .padding(1)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Panel content

struct MenuBarContentView: View {
    var dismissPopover: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            commandDeck
                .padding(.horizontal, 16)

            if PinnedScreenshotController.shared.hasPinnedWindows {
                pinnedRow
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            RecentCaptureLedger(
                records: Array(HistoryStore.shared.records.prefix(3)),
                onOpen: open,
                onShowAll: openLibrary,
                onCapture: { dismissAndRun(.main) }
            )
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
        }
        .frame(width: 660)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RuneBrandIcon(size: 24)

            Text("Rune")
                .font(RuneFont.swiftUI(size: 16, weight: .semibold))
                .foregroundStyle(RuneTheme.chromeText)

            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(RuneFont.mono(size: 9, weight: .medium))
                .foregroundStyle(RuneTheme.textMuted)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                RuneGlyph(systemImage: "power", size: 13)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("退出 Rune (⌘Q)")
            .accessibilityLabel("退出 Rune")
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    /// 截图是唯一主入口；其余能力作为同一玻璃仪表台上的辅助命令。
    private var commandDeck: some View {
        VStack(spacing: 0) {
            Button {
                dismissAndRun(.main)
            } label: {
                MenuPrimaryCaptureLabel(
                    shortcut: ShortcutService.shared.displayString(for: .main)
                )
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("开始截图 · \(ShortcutService.shared.displayString(for: .main))")
            .accessibilityLabel("开始截图")

            RuneTheme.hairline
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
                MenuCommandButton(
                    title: "连拍",
                    icon: "square.stack.3d.up",
                    shortcut: ShortcutService.shared.displayString(for: .burst)
                ) {
                    dismissAndRunBurst(mode: .burst)
                }

                MenuCommandButton(title: "长图", icon: "arrow.down.doc") {
                    dismissAndRunScrollCapture()
                }

                MenuCommandButton(title: "文字", icon: "text.viewfinder") {
                    dismissAndRun(.ocr)
                }

                recordingCommand

                MenuCommandButton(
                    title: "取色",
                    icon: "eyedropper",
                    shortcut: ShortcutService.shared.displayString(for: .colorPicker)
                ) {
                    dismissAndRun(.colorPicker)
                }

                MenuCommandButton(title: "素材库", icon: "rectangle.stack") {
                    openLibrary()
                }

                MenuCommandButton(title: "设置", icon: "gearshape") {
                    openSettings()
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .runeGlassSurface(
            cornerRadius: RuneTheme.barCorner,
            tint: RuneTheme.glassTint,
            interactive: true,
            elevation: .embedded
        )
    }

    private var recordingCommand: some View {
        RuneMenu(
            surface: .chrome,
            entries: {
                [
                    .item(RuneMenuItem("全屏录制", systemImage: "desktopcomputer") {
                        startRecordingFromMenu(mode: .fullScreen)
                    }),
                    .item(RuneMenuItem("区域录制", systemImage: "rectangle.dashed") {
                        startRecordingFromMenu(mode: .area)
                    }),
                ]
            }
        ) {
            MenuCommandLabel(title: "录屏", icon: "record.circle", showsMenu: true)
        }
        .help("选择全屏或区域录制")
        .accessibilityLabel("录屏，选择全屏或区域")
    }

    private var pinnedRow: some View {
        HStack(spacing: 10) {
            RuneGlyph(systemImage: "pin", size: 12)

            Text("\(PinnedScreenshotController.shared.pinnedCount) 张贴图正在桌面显示")
                .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)

            Spacer()

            if PinnedScreenshotController.shared.hasPassthroughWindows {
                Button("恢复交互") {
                    PinnedScreenshotController.shared.restoreInteractions()
                }
                .buttonStyle(.plain)
                .foregroundStyle(RuneTheme.textSecondary)
            }

            Button("全部关闭") {
                PinnedScreenshotController.shared.unpinAll()
                dismissPopover()
            }
            .buttonStyle(.plain)
            .foregroundStyle(RuneTheme.textSecondary)
        }
        .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RuneTheme.graphite.opacity(0.72))
        .overlay(alignment: .bottom) { RuneTheme.hairline }
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

    private func openLibrary() {
        let screen = originScreen
        dismissPopover()
        CaptureLibraryWindowController.shared.open(on: screen)
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

// MARK: - Main command rail

private struct MenuPrimaryCaptureLabel: View {
    let shortcut: String

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 13) {
            RuneOpticalIconPlate(
                systemImage: "camera.viewfinder",
                isActive: true,
                size: 38
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("开始截图")
                    .font(RuneFont.swiftUI(size: 13.5, weight: .semibold))
                    .foregroundStyle(RuneTheme.textPrimary)
                Text("拖选区域 · 点击窗口 · 点击桌面")
                    .font(RuneFont.swiftUI(size: 10.5))
                    .foregroundStyle(RuneTheme.textSecondary)
            }

            Spacer(minLength: 14)

            Text(shortcut)
                .font(RuneFont.mono(size: 10, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RuneTheme.chipCorner, style: .continuous)
                        .strokeBorder(RuneTheme.separator, lineWidth: 0.7)
                )

            Image(systemName: "chevron.right")
                .font(RuneFont.swiftUI(size: 9, weight: .semibold))
                .foregroundStyle(RuneTheme.textMuted)
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.045) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct MenuCommandButton: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuCommandLabel(
                title: title,
                icon: icon,
                shortcut: shortcut,
                isPrimary: isPrimary
            )
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .help(shortcut.map { "\(title) · \($0)" } ?? title)
        .accessibilityLabel(shortcut.map { "\(title)，快捷键 \($0)" } ?? title)
    }
}

private struct MenuCommandLabel: View {
    let title: String
    let icon: String
    var shortcut: String? = nil
    var isPrimary = false
    var showsMenu = false

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            RuneGlyph(systemImage: icon, isActive: isPrimary || isHovered, size: 17)
                .frame(height: 19)

            Text(title)
                .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                .foregroundStyle(isHovered || isPrimary ? RuneTheme.textPrimary : RuneTheme.textSecondary)
                .lineLimit(1)

            Group {
                if let shortcut, !shortcut.isEmpty {
                    Text(shortcut)
                        .font(RuneFont.mono(size: 8, weight: .medium))
                        .foregroundStyle(RuneTheme.textMuted)
                        .lineLimit(1)
                } else if showsMenu {
                    Image(systemName: "chevron.down")
                        .font(RuneFont.swiftUI(size: 7, weight: .semibold))
                        .foregroundStyle(RuneTheme.textMuted)
                } else {
                    Color.clear.frame(height: 9)
                }
            }
            .frame(height: 9)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.045) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recent capture ledger

private struct RecentCaptureLedger: View {
    let records: [CaptureRecord]
    let onOpen: (CaptureRecord) -> Void
    let onShowAll: () -> Void
    let onCapture: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("最近素材")
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                    .foregroundStyle(RuneTheme.textPrimary)

                if !records.isEmpty {
                    Text("\(records.count)")
                        .font(RuneFont.mono(size: 9, weight: .medium))
                        .foregroundStyle(RuneTheme.textMuted)
                }

                Spacer()

                Button(action: onShowAll) {
                    HStack(spacing: 4) {
                        Text("查看全部")
                        Image(systemName: "chevron.right")
                            .font(RuneFont.swiftUI(size: 8, weight: .semibold))
                    }
                    .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看全部素材")
            }
            .padding(.bottom, 10)

            if records.isEmpty {
                HStack(spacing: 12) {
                    RuneGlyph(systemImage: "rectangle.stack", size: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("还没有素材")
                            .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                            .foregroundStyle(RuneTheme.textPrimary)
                        Text("截图和录屏会按时间出现在这里")
                            .font(RuneFont.swiftUI(size: 10.5))
                            .foregroundStyle(RuneTheme.textMuted)
                    }

                    Spacer()

                    Button(action: onCapture) {
                        RuneTheme.primaryButtonLabel("开始截图")
                    }
                    .buttonStyle(RuneTheme.RunePressStyle())
                }
                .frame(height: 64)
                .overlay(alignment: .bottom) { RuneTheme.hairline }
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    RecentCaptureLedgerRow(record: record, onOpen: onOpen)

                    if index < records.count - 1 {
                        RuneTheme.hairline
                    }
                }
            }
        }
    }
}

private struct RecentCaptureLedgerRow: View {
    let record: CaptureRecord
    let onOpen: (CaptureRecord) -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovered = false
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 12) {
            Button { onOpen(record) } label: {
                ZStack {
                    RuneTheme.graphiteRaised

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().controlSize(.mini)
                    }

                    if record.kind == .recording {
                        Image(systemName: "play.fill")
                            .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(.black.opacity(0.62), in: Circle())
                    }
                }
                .frame(width: 80, height: 45)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(isHovered ? RuneTheme.cyan.opacity(0.65) : RuneTheme.separator, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(RuneFont.swiftUI(size: 11.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(record.createdAt, style: .relative)
                    Text("·")
                    Text("\(record.pixelWidth) × \(record.pixelHeight)")
                }
                .font(RuneFont.mono(size: 9.5, weight: .regular))
                .foregroundStyle(RuneTheme.textMuted)
                .monospacedDigit()
            }

            Spacer()

            Button {
                copyRecord()
            } label: {
                RuneGlyph(systemImage: isCopied ? "checkmark" : "doc.on.doc", isActive: isCopied, size: 12)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(isCopied ? "已复制" : "复制")
            .accessibilityLabel(isCopied ? "已复制 \(record.displayName)" : "复制 \(record.displayName)")

            Button { onOpen(record) } label: {
                RuneGlyph(systemImage: record.kind == .recording ? "play" : "pin", size: 12)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(record.kind == .recording ? "预览录屏" : "贴到屏幕")
            .accessibilityLabel(record.kind == .recording ? "预览 \(record.displayName)" : "贴图 \(record.displayName)")
        }
        .frame(height: 62)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .task(id: record.id) {
            let url = HistoryStore.shared.displayURLForRecord(record)
            let kind = record.kind
            let cgImage = await Task.detached(priority: .utility) {
                HistoryStore.renderThumbnailCGImage(at: url, kind: kind, maxSize: 240)
            }.value
            if let cgImage {
                thumbnail = NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }
    }

    private func copyRecord() {
        let url = HistoryStore.shared.displayURLForRecord(record)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let didCopy: Bool
        if record.kind == .recording {
            didCopy = pasteboard.writeObjects([url as NSURL])
        } else if let image = NSImage(contentsOf: url) {
            didCopy = pasteboard.writeObjects([image])
        } else {
            didCopy = false
        }
        guard didCopy else { return }
        HistoryStore.shared.markUsed(record.id)
        isCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            isCopied = false
        }
    }
}
