import AppKit
import AVFoundation
import SwiftUI

/// 录制前的设置面板（飞书录屏面板同款）。
///
/// 飞书在开始录制前会摆出一块面板：输出格式、扬声器、麦克风、摄像头（画中画）、
/// 鼠标设置。Rune 之前是"按热键就开始录"，这些选择只能去偏好设置里翻，
/// 而且扬声器与麦克风根本没有分开（代码里麦克风那个通道是空的）。
///
/// 面板只负责"问用户想要什么"，存哪儿、怎么开录由调用方决定。
@MainActor
final class RecordingOptionsPanelController {
    static let shared = RecordingOptionsPanelController()

    private var panel: NSPanel?
    private var continuation: CheckedContinuation<RecordingOptions?, Never>?

    private init() {}

    /// 弹出面板等用户选。返回 nil 表示用户取消。
    func present(options: RecordingOptions, on screen: NSScreen?) async -> RecordingOptions? {
        dismiss()
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let root = RecordingOptionsView(
                initial: options,
                onStart: { [weak self] chosen in
                    self?.finish(with: chosen)
                },
                onCancel: { [weak self] in
                    self?.finish(with: nil)
                }
            )
            .runeTypography()

            let size = CGSize(width: 320, height: 372)
            let host = NSHostingView(rootView: root)
            host.frame = CGRect(origin: .zero, size: size)

            let panel = NSPanel(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentView = host

            if let target {
                let visible = target.visibleFrame
                panel.setFrameOrigin(
                    NSPoint(
                        x: visible.midX - size.width / 2,
                        y: visible.midY - size.height / 2
                    )
                )
            }
            panel.orderFrontRegardless()
            self.panel = panel
        }
    }

    private func finish(with options: RecordingOptions?) {
        let pending = continuation
        continuation = nil
        dismiss()
        pending?.resume(returning: options)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        if let pending = continuation {
            continuation = nil
            pending.resume(returning: nil)
        }
    }
}

/// 面板本体。
private struct RecordingOptionsView: View {
    @State private var options: RecordingOptions
    let onStart: (RecordingOptions) -> Void
    let onCancel: () -> Void

    /// 硬件可用性：没有麦克风/摄像头的机器要把开关置灰并说明原因，
    /// 而不是让人点了才发现没反应。
    private let microphoneState = RecordingHardwareState.microphone()
    private let cameraState = RecordingHardwareState.camera()

    init(initial: RecordingOptions, onStart: @escaping (RecordingOptions) -> Void, onCancel: @escaping () -> Void) {
        _options = State(initialValue: initial)
        self.onStart = onStart
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 10) {
                formatRow
                Divider().overlay(Color.white.opacity(0.10))
                audioRows
                Divider().overlay(Color.white.opacity(0.10))
                cameraRow
                Divider().overlay(Color.white.opacity(0.10))
                mouseRows
                Divider().overlay(Color.white.opacity(0.10))
                fpsRow
            }

            buttons
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
        .frame(width: 288)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "record.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RuneTheme.signal)
            Text("录制设置")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
            Spacer(minLength: 0)
        }
    }

    // 格式

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            rowTitle("输出格式")
            HStack(spacing: 6) {
                ForEach(VideoExportFormat.allCases) { format in
                    segmentButton(
                        title: format.title,
                        isSelected: options.format == format
                    ) {
                        options.format = format
                    }
                }
            }
        }
    }

    // 音频

    private var audioRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowTitle("声音")
            toggleRow(
                title: "扬声器",
                systemImage: "speaker.wave.2",
                isOn: options.captureSystemAudio,
                unavailableReason: nil
            ) {
                options.captureSystemAudio.toggle()
            }
            toggleRow(
                title: "麦克风",
                systemImage: "mic",
                isOn: options.captureMicrophone,
                unavailableReason: microphoneState.reason
            ) {
                options.captureMicrophone.toggle()
            }
        }
    }

    // 摄像头

    private var cameraRow: some View {
        toggleRow(
            title: "摄像头",
            systemImage: "video",
            isOn: options.captureCamera,
            unavailableReason: cameraState.reason
        ) {
            options.captureCamera.toggle()
        }
    }

    // 鼠标

    private var mouseRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowTitle("鼠标")
            toggleRow(
                title: "显示鼠标",
                systemImage: "cursorarrow",
                isOn: options.showCursor,
                unavailableReason: nil
            ) {
                options.showCursor.toggle()
            }
            toggleRow(
                title: "点击高亮",
                systemImage: "circle.dotted",
                isOn: options.highlightMouseClicks,
                unavailableReason: ScreenRecordingManager.supportsClickHighlight ? nil : "需要 macOS 15 或更高版本"
            ) {
                options.highlightMouseClicks.toggle()
            }
        }
    }

    // 帧率

    private var fpsRow: some View {
        HStack {
            rowTitle("帧率")
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach([30, 60], id: \.self) { fps in
                    segmentButton(title: "\(fps)", isSelected: options.fps == fps) {
                        options.fps = fps
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(action: onCancel) {
                Text("取消")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消录制")

            Button {
                onStart(options)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("开始录制")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color.black.opacity(0.88))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RuneTheme.primaryFill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel("开始录制")

            Spacer(minLength: 0)
        }
    }

    // MARK: - 零件

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.45))
    }

    private func segmentButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black.opacity(0.86) : Color.white.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? RuneTheme.cyan : Color.white.opacity(0.08))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func toggleRow(
        title: String,
        systemImage: String,
        isOn: Bool,
        unavailableReason: String?,
        action: @escaping () -> Void
    ) -> some View {
        let isDisabled = unavailableReason != nil
        return HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(isDisabled ? 0.28 : 0.62))
                .frame(width: 16)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(isDisabled ? 0.35 : 0.88))
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.32))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            toggle(isOn: isOn, isDisabled: isDisabled, title: title, action: action)
        }
    }

    private func toggle(
        isOn: Bool,
        isDisabled: Bool,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? RuneTheme.cyan : Color.white.opacity(0.14))
                    .frame(width: 34, height: 19)
                Circle()
                    .fill(isOn ? Color.black.opacity(0.75) : Color.white.opacity(0.75))
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "已开启" : "已关闭")
    }
}

/// 麦克风 / 摄像头的硬件可用性。
enum RecordingHardwareState {
    static func microphone() -> (hasDevice: Bool, reason: String?) {
        guard ScreenRecordingManager.supportsMicrophoneCapture else {
            return (false, "需要 macOS 15 或更高版本")
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        if devices.isEmpty { return (false, "此设备没有麦克风") }
        return (true, nil)
    }

    static func camera() -> (hasDevice: Bool, reason: String?) {
        let availability = CameraFrameProvider.availability()
        if !availability.hasDevice { return (false, "此设备没有摄像头") }
        if !availability.isAuthorized { return (false, "尚未授权摄像头") }
        return (true, nil)
    }
}
