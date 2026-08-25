import AppKit
import SwiftUI

/// 录屏中的常驻状态条：状态、时长和停止始终可见；低频危险动作收进更多菜单。
struct RecordingStatusBarView: View {
    @State private var recorder = ScreenRecordingManager.shared

    let auditElapsedSeconds: Int?
    let auditPaused: Bool

    init(auditElapsedSeconds: Int? = nil, auditPaused: Bool = false) {
        self.auditElapsedSeconds = auditElapsedSeconds
        self.auditPaused = auditPaused
    }

    private var isPaused: Bool {
        auditElapsedSeconds == nil ? recorder.state == .paused : auditPaused
    }

    private var elapsedSeconds: Int {
        auditElapsedSeconds ?? recorder.elapsedSeconds
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isPaused ? RuneTheme.chromeMuted : RuneTheme.signal)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(isPaused ? "录屏已暂停" : "正在录屏")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .foregroundStyle(RuneTheme.chromeText)

                Text(formatTime(elapsedSeconds))
                    .font(RuneFont.mono(size: 12, weight: .medium))
                    .foregroundStyle(RuneTheme.chromeText.opacity(0.72))
                    .contentTransition(.numericText())
            }
            .frame(minWidth: 72, alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 24)

            Button {
                recorder.togglePause()
            } label: {
                Label(isPaused ? "继续" : "暂停", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.09), in: Capsule())
            }
            .buttonStyle(RecordingControlButtonStyle())
            .accessibilityLabel(isPaused ? "继续录屏" : "暂停录屏")

            RuneMenu(
                surface: .chrome,
                entries: {
                    [
                        .item(
                            RuneMenuItem("放弃这段录屏", systemImage: "trash", isDestructive: true) {
                                RecordingStatusBarController.shared.confirmAndCancel()
                            }
                        ),
                    ]
                }
            ) {
                Image(systemName: "ellipsis")
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.09), in: Circle())
            }
            .help("更多录屏操作")
            .accessibilityLabel("更多录屏操作")

            Button {
                RecordingStatusBarController.shared.finishRecording()
            } label: {
                Label("结束", systemImage: "stop.fill")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(RuneTheme.chromeBlueFill, in: Capsule())
            }
            .buttonStyle(RecordingControlButtonStyle())
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("结束并保存录屏")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(RuneTheme.chromeBase.opacity(0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(RuneTheme.chromeLine, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.34), radius: 12, y: 4)
        )
    }

    private func formatTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let seconds = seconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct RecordingControlButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : (isHovered ? 0.88 : 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

@MainActor
final class RecordingStatusBarController {
    static let shared = RecordingStatusBarController()

    private var panel: NSPanel?
    private var targetScreen: NSScreen?

    private init() {}

    func show(
        on preferredScreen: NSScreen? = nil,
        auditElapsedSeconds: Int? = nil,
        auditPaused: Bool = false
    ) {
        dismiss()
        targetScreen = preferredScreen

        let rootView = RecordingStatusBarView(
            auditElapsedSeconds: auditElapsedSeconds,
            auditPaused: auditPaused
        )
        .environment(\.colorScheme, .dark)
        .runeTypography()

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.contentView = hostingView

        let screen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.maxY - panel.frame.height - 16
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFront(nil)
        self.panel = panel
    }

    func finishRecording() {
        guard ScreenRecordingManager.shared.isRecording else { return }
        let screen = targetScreen
        dismiss()

        Task {
            if let url = await ScreenRecordingManager.shared.stopRecording() {
                let record = await HistoryStore.shared.importCapture(
                    from: url,
                    deleteSource: false,
                    kind: .recording
                )
                if let record {
                    PreviewOverlay.shared.show(
                        url: HistoryStore.shared.urlForRecord(record),
                        on: screen
                    )
                } else {
                    ToastWindow.shared.show(
                        title: "录屏已保存",
                        message: "文件已写入保存文件夹，但没有加入最近记录",
                        systemIcon: "exclamationmark.triangle",
                        on: screen
                    )
                    PreviewOverlay.shared.show(url: url, on: screen)
                }
            } else {
                ToastWindow.shared.show(
                    title: "录屏保存失败",
                    message: "没有生成可用的视频，请检查磁盘空间后重试",
                    systemIcon: "exclamationmark.triangle",
                    on: screen
                )
            }
        }
    }

    func confirmAndCancel() {
        guard ScreenRecordingManager.shared.isRecording else { return }

        let alert = NSAlert()
        alert.messageText = "放弃这段录屏？"
        alert.informativeText = "当前录制内容不会保存。"
        alert.addButton(withTitle: "放弃录屏")
        alert.addButton(withTitle: "继续录制")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        dismiss()
        Task {
            await ScreenRecordingManager.shared.cancelRecording()
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        targetScreen = nil
    }
}
