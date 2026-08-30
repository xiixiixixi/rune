import AppKit
@preconcurrency import AVFoundation
import SwiftUI

private enum PreviewCardMetrics {
    static let panelSize = CGSize(width: 304, height: 264)
    static let cardSize = CGSize(width: 280, height: 240)
    static let mediaSize = CGSize(width: 256, height: 154)
}

/// 截图或录屏完成后的轻量结果卡。文件已经保存，卡片只承接下一步动作。
@MainActor
@Observable
final class PreviewOverlay {
    static let shared = PreviewOverlay()

    private(set) var currentURL: URL?
    private(set) var currentKind: CaptureKind = .screenshot
    private(set) var isVisible = false
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?
    private var targetScreen: NSScreen?

    private init() {}

    func show(
        url: URL,
        on screen: NSScreen? = nil,
        kindOverride: CaptureKind? = nil
    ) {
        dismissTask?.cancel()
        currentURL = url
        currentKind = kindOverride ?? (isVideo(url) ? .recording : .screenshot)
        targetScreen = screen
        isVisible = true

        if panel == nil {
            createPanel()
        }

        positionPanel()
        panel?.orderFront(nil)
        scheduleDismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
        isVisible = false
        currentURL = nil
        currentKind = .screenshot
    }

    func pauseAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func resumeAutoDismiss() {
        scheduleDismiss()
    }

    func openEditor() {
        guard let url = currentURL else { return }
        let screen = targetScreen
        let kind = currentKind
        dismiss()
        if kind == .recording {
            VideoEditorWindowController.shared.open(url: url, on: screen)
        } else {
            EditorWindowController.shared.open(url: url, on: screen)
        }
    }

    func pinScreenshot() {
        guard let url = currentURL, currentKind == .screenshot else { return }
        let screen = targetScreen
        dismiss()
        PinnedScreenshotController.shared.pin(url: url, on: screen)
    }

    func revealInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        dismiss()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: PreviewCardMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(
            rootView: PreviewCardView(overlay: self).runeTypography()
        )
        self.panel = panel
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = targetScreen
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
        guard let panel, let screen else { return }

        let visible = screen.visibleFrame
        let size = PreviewCardMetrics.panelSize
        let inset: CGFloat = 16
        let x: CGFloat

        switch AppPreferences.overlayPosition {
        case .bottomRight:
            x = visible.maxX - size.width - inset
        case .bottomLeft:
            x = visible.minX + inset
        }

        panel.setFrame(
            NSRect(
                origin: NSPoint(x: x, y: visible.minY + inset),
                size: size
            ),
            display: true
        )
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(AppPreferences.overlayDismissDelay))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func isVideo(_ url: URL) -> Bool {
        ["mov", "mp4"].contains(url.pathExtension.lowercased())
    }
}

struct PreviewCardView: View {
    let overlay: PreviewOverlay

    @State private var thumbnail: NSImage?

    private var isVideo: Bool {
        overlay.currentKind == .recording
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            footer
        }
        .frame(
            width: PreviewCardMetrics.cardSize.width,
            height: PreviewCardMetrics.cardSize.height
        )
        .runeGlassSurface(cornerRadius: RuneTheme.cardCorner, elevation: .floating)
        .frame(
            width: PreviewCardMetrics.panelSize.width,
            height: PreviewCardMetrics.panelSize.height,
            alignment: .bottomTrailing
        )
        .onHover { hovering in
            if hovering {
                overlay.pauseAutoDismiss()
            } else {
                overlay.resumeAutoDismiss()
            }
        }
        .onChange(of: overlay.currentURL) { _, newURL in
            loadThumbnail(from: newURL)
        }
        .onAppear {
            loadThumbnail(from: overlay.currentURL)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            if isVideo {
                RuneOpticalIconPlate(systemImage: "record.circle", size: 22)
            } else {
                RuneSelectionMark(isSelected: true, size: 16)
            }

            Text(isVideo ? "录屏已保存" : "截图已保存")
                .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                .foregroundStyle(RuneTheme.chromeText)

            Spacer()

            Button {
                overlay.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(RuneFont.swiftUI(size: 10, weight: .semibold))
                    .foregroundStyle(RuneTheme.chromeMuted)
                    .frame(width: 24, height: 24)
                    .background(RuneTheme.chromeBase, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭预览")
            .accessibilityLabel("关闭预览")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    private var preview: some View {
        ZStack {
            RuneTheme.workspace

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: PreviewCardMetrics.mediaSize.width,
                        height: PreviewCardMetrics.mediaSize.height
                    )
                    .clipped()
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            if isVideo {
                Image(systemName: "play.circle.fill")
                    .font(RuneFont.swiftUI(size: 30))
                    .foregroundStyle(.white.opacity(0.94))
                    .shadow(color: .black.opacity(0.34), radius: 4, y: 2)
            }
        }
        .frame(
            width: PreviewCardMetrics.mediaSize.width,
            height: PreviewCardMetrics.mediaSize.height
        )
        .clipShape(RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                .strokeBorder(RuneTheme.chromeLine, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { overlay.openEditor() }
        .onDrag {
            if let url = overlay.currentURL {
                return NSItemProvider(object: url as NSURL)
            }
            return NSItemProvider()
        }
        .help(isVideo ? "打开录屏编辑器，也可以直接拖到其他应用" : "打开截图编辑器，也可以直接拖到其他应用")
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if isVideo {
                Button {
                    overlay.openEditor()
                } label: {
                    RuneTheme.primaryButtonLabel("剪辑", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(RuneTheme.RunePressStyle())
            } else {
                Button {
                    guard let thumbnail else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.writeObjects([thumbnail])
                    overlay.dismiss()
                } label: {
                    RuneTheme.primaryButtonLabel("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(RuneTheme.RunePressStyle())
                .disabled(thumbnail == nil)

                actionButton("pin", help: "贴在桌面上") {
                    overlay.pinScreenshot()
                }

                actionButton("pencil", help: "打开编辑器") {
                    overlay.openEditor()
                }
            }

            Spacer(minLength: 4)

            actionButton("folder", help: "在访达中显示") {
                overlay.revealInFinder()
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func actionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                .foregroundStyle(RuneTheme.chromeMuted)
                .frame(width: 34, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RuneTheme.buttonCorner, style: .continuous)
                        .strokeBorder(RuneTheme.chromeLine.opacity(0.8), lineWidth: 0.5)
                )
        }
        .buttonStyle(RuneTheme.RunePressStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func loadThumbnail(from url: URL?) {
        guard let url else {
            thumbnail = nil
            return
        }

        if isVideo, ["mov", "mp4"].contains(url.pathExtension.lowercased()) {
            Task {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 448, height: 252)
                if let result = try? await generator.image(at: .zero) {
                    let cgImage = result.image
                    let image = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    thumbnail = image
                }
            }
        } else {
            thumbnail = NSImage(contentsOf: url)
        }
    }
}
