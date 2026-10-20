import Foundation

/// 录制选项（飞书录屏面板同款）。
///
/// 飞书在「开始录制」之前给一块设置面板：输出格式、扬声器、麦克风、摄像头（画中画）、
/// 鼠标设置。Rune 早期只有一个「录制音频」总开关（走系统音频），麦克风通道虽然写在了
/// 代码里（`SCStreamOutputType.microphone`），但那个分支是空的——从来没有真正接过。
/// 这里把录制前的选择显式建模出来，面板、偏好设置、录制管理器共用同一份数据。
struct RecordingOptions: Equatable, Sendable {
    /// 输出格式。GIF 是飞书录屏同款，可以直接贴进聊天。
    var format: VideoExportFormat = .mp4
    /// 扬声器：录系统 / 应用声音。
    var captureSystemAudio: Bool = false
    /// 麦克风：录人声。与扬声器互相独立，可以只开一个。
    var captureMicrophone: Bool = false
    /// 摄像头：画中画，叠在录制画面右下角。
    var captureCamera: Bool = false
    /// 显示鼠标指针。
    var showCursor: Bool = true
    /// 鼠标点击高亮：点击处画一个圈（系统自带，不额外合成）。
    var highlightMouseClicks: Bool = false
    /// 帧率。
    var fps: Int = 30

    /// 偏好设置里的当前值，作为录制面板的初始状态。
    static func fromPreferences() -> RecordingOptions {
        RecordingOptions(
            format: AppPreferences.recordingFormat,
            captureSystemAudio: AppPreferences.recordingCaptureAudio,
            captureMicrophone: AppPreferences.recordingCaptureMicrophone,
            captureCamera: AppPreferences.recordingCaptureCamera,
            showCursor: AppPreferences.recordingShowCursor,
            highlightMouseClicks: AppPreferences.recordingHighlightClicks,
            fps: AppPreferences.recordingFPS
        )
    }

    /// 存回偏好设置，下次录制沿用。
    func saveToPreferences() {
        AppPreferences.recordingFormat = format
        AppPreferences.recordingCaptureAudio = captureSystemAudio
        AppPreferences.recordingCaptureMicrophone = captureMicrophone
        AppPreferences.recordingCaptureCamera = captureCamera
        AppPreferences.recordingShowCursor = showCursor
        AppPreferences.recordingHighlightClicks = highlightMouseClicks
        AppPreferences.recordingFPS = fps
    }

    /// 是否需要把声音写进文件（任一路开启即可）。
    var hasAnyAudio: Bool { captureSystemAudio || captureMicrophone }
}
