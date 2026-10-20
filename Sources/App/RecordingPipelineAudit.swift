import AppKit
import AVFoundation
import Foundation

/// 录屏管线真机验收通道（DEBUG）。
///
/// 这条通道跑的是**真实录制链路**：ScreenCaptureKit 出画面、写入器落盘，
/// 录完再回头检查文件里到底有几条轨、每条轨里是什么内容。
///
/// 命令行参数：
/// - `--audit-recording`                开启验收
/// - `--audit-recording-seconds=N`      录多久（默认 4 秒）
/// - `--audit-recording-audio=1`        录扬声器（系统声音）
/// - `--audit-recording-mic=1`          录麦克风
/// - `--audit-recording-camera=1`       录摄像头画中画
/// - `--audit-recording-clicks=1`       鼠标点击高亮
/// - `--audit-recording-click=X,Y`      在屏幕坐标点一下（会先挪鼠标再开录）
/// - `--audit-recording-out=路径`        报告输出路径
enum RecordingPipelineAudit {

    @MainActor
    static func run() async {
        let arguments = ProcessInfo.processInfo.arguments

        // 只把设置面板摆出来（不开始录制），用来验收面板本身。
        if arguments.contains("--audit-recording-panel") {
            let outputPath = argumentValue("audit-recording-out") ?? "/tmp/rune-recording-panel-audit.txt"
            var options = RecordingOptions()
            options.captureSystemAudio = true
            options.captureMicrophone = true
            options.captureCamera = true
            options.highlightMouseClicks = true

            // 等应用完全跑起来再弹：启动阶段里弹的窗口可能不显示。
            try? await Task.sleep(for: .milliseconds(1500))
            let chosen = await RecordingOptionsPanelController.shared.present(
                options: options,
                on: NSScreen.main
            )
            let text = chosen.map { "面板已确认: 扬声器=\($0.captureSystemAudio) 麦克风=\($0.captureMicrophone) "
                + "摄像头=\($0.captureCamera) 点击高亮=\($0.highlightMouseClicks) 格式=\($0.format.rawValue)" }
                ?? "面板被取消"
            try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        func argumentValue(_ key: String) -> String? {
            guard let argument = arguments.first(where: { $0.hasPrefix("--\(key)=") }) else { return nil }
            return String(argument.dropFirst("--\(key)=".count))
        }

        func value(_ key: String) -> String? {
            guard let argument = arguments.first(where: { $0.hasPrefix("--\(key)=") }) else { return nil }
            return String(argument.dropFirst("--\(key)=".count))
        }
        func flag(_ key: String) -> Bool {
            value(key) == "1" || arguments.contains("--\(key)")
        }

        let outputPath = value("audit-recording-out") ?? "/tmp/rune-recording-audit.txt"
        let seconds = Double(value("audit-recording-seconds") ?? "4") ?? 4

        var options = RecordingOptions()
        options.captureSystemAudio = flag("audit-recording-audio")
        options.captureMicrophone = flag("audit-recording-mic")
        options.captureCamera = flag("audit-recording-camera")
        options.highlightMouseClicks = flag("audit-recording-clicks")
        options.showCursor = true
        options.fps = 30

        func report(_ text: String) {
            try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        var lines: [String] = []
        lines.append("=== 录屏管线验收 ===")
        lines.append("选项: 扬声器=\(options.captureSystemAudio) 麦克风=\(options.captureMicrophone) "
            + "摄像头=\(options.captureCamera) 点击高亮=\(options.highlightMouseClicks) 时长=\(seconds)s")
        lines.append("能力: 麦克风通道=\(ScreenRecordingManager.supportsMicrophoneCapture) "
            + "点击高亮=\(ScreenRecordingManager.supportsClickHighlight)")
        let cameraAvailability = CameraFrameProvider.availability()
        lines.append("硬件: 摄像头设备=\(cameraAvailability.hasDevice) 已授权=\(cameraAvailability.isAuthorized) "
            + "原因=\(cameraAvailability.reason ?? "无")")
        lines.append("硬件: 麦克风设备=\(ScreenRecordingManager.microphoneDeviceAvailable)")

        // 点击位置：先把鼠标挪到位再开录
        let clickPoint: CGPoint? = value("audit-recording-click").flatMap { raw in
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        if let clickPoint {
            startMouseMonitor()
            // 先把鼠标挪到位再开录：这样录制前后画面里唯一的变化就是「点击高亮」，
            // 而不是「光标刚跑过去」。否则测出来的是光标，不是高亮圈。
            moveMouse(to: clickPoint)
            try? await Task.sleep(for: .milliseconds(400))
        }

        // 开录
        do {
            let started = try await ScreenRecordingManager.shared.startFullScreenRecording(
                on: NSScreen.main,
                options: options
            )
            guard started else {
                report(lines.joined(separator: "\n") + "\nFAIL: 录制没启动")
                return
            }
        } catch {
            report(lines.joined(separator: "\n") + "\nFAIL: 录制抛错 \(error.localizedDescription)")
            return
        }
        lines.append("录制已启动")
        RecordingStatusBarController.shared.show(on: NSScreen.main)

        if let clickPoint {
            try? await Task.sleep(for: .milliseconds(1200))
            postClick(at: clickPoint)
            lines.append("已在 \(Int(clickPoint.x)),\(Int(clickPoint.y)) 模拟点击")
        }

        try? await Task.sleep(for: .seconds(seconds))

        guard let url = await ScreenRecordingManager.shared.stopRecording() else {
            report(lines.joined(separator: "\n") + "\nFAIL: 停止后没有拿到文件")
            return
        }
        lines.append("文件: \(url.path)")
        stopMouseMonitor()
        lines.append("全局监听到的鼠标按下次数: \(mouseCounter.value)")

        lines += await fileReport(url: url, requested: options)
        report(lines.joined(separator: "\n"))
    }

    /// 检查录出来的文件结构。
    @MainActor
    private static func fileReport(
        url: URL,
        requested: RecordingOptions
    ) async -> [String] {
        var lines: [String] = []
        let asset = AVURLAsset(url: url)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let active = ScreenRecordingManager.shared.activeOptions

        lines.append("大小: \(bytes ?? 0) 字节  时长: \(String(format: "%.2f", duration)) 秒")
        lines.append("轨道: 视频 \(videoTracks.count) 条 / 音频 \(audioTracks.count) 条")
        if let track = videoTracks.first {
            let size = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let transformed = size.applying(transform)
            lines.append("画面尺寸: \(Int(abs(transformed.width)))x\(Int(abs(transformed.height))) 点")
        }
        for (index, track) in audioTracks.enumerated() {
            let trackDuration = (try? await track.load(.timeRange))?.duration.seconds ?? 0
            lines.append("  音频轨 \(index + 1): 时长 \(String(format: "%.2f", trackDuration)) 秒")
        }
        lines.append("实际生效: 扬声器=\(active.captureSystemAudio) 麦克风=\(active.captureMicrophone) "
            + "摄像头=\(active.captureCamera) 点击高亮=\(active.highlightMouseClicks)")

        if videoTracks.isEmpty {
            lines.append("FAIL: 没有视频轨")
        }
        if active.captureSystemAudio && audioTracks.isEmpty {
            lines.append("FAIL: 开了扬声器却没有音频轨")
        }
        if active.captureMicrophone && audioTracks.count < 2 {
            lines.append("FAIL: 麦克风已生效但音频轨少于 2 条")
        }
        if requested.captureMicrophone && !active.captureMicrophone {
            lines.append("说明: 麦克风因硬件/权限不可用被关闭，已自动降级为只录扬声器")
        }
        if requested.captureCamera && !active.captureCamera {
            lines.append("说明: 摄像头因硬件/权限不可用被关闭，已自动降级")
        }
        return lines
    }

    /// 全局鼠标事件计数：用来分辨「模拟点击没送达系统」还是「高亮没画出来」。
    /// 鼠标事件的全局监听不需要辅助功能权限（键盘才需要）。
    private static let mouseCounter = MouseCounter()
    private static let mouseMonitorBox = MonitorBox()

    /// 鼠标按下计数（跨线程安全）
    private final class MouseCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }
        var value: Int { lock.withLock { count } }
    }

    /// 全局监听器句柄（跨线程安全）
    private final class MonitorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var monitor: Any?
        func set(_ value: Any?) {
            lock.lock(); monitor = value; lock.unlock()
        }
        var value: Any? { lock.withLock { monitor } }
    }

    /// 全局鼠标事件计数：用来分辨「模拟点击没送达系统」还是「高亮没画出来」。
    /// 鼠标事件的全局监听不需要辅助功能权限（键盘才需要）。
    private static func startMouseMonitor() {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            mouseCounter.increment()
        }
        mouseMonitorBox.set(monitor)
    }

    private static func stopMouseMonitor() {
        if let monitor = mouseMonitorBox.value {
            NSEvent.removeMonitor(monitor)
        }
        mouseMonitorBox.set(nil)
    }

    /// 把鼠标挪到指定位置（不点击）。
    private static func moveMouse(to point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                              mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
    }

    /// 合成一次鼠标点击（系统级事件，录屏能看见）。
    private static func postClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                              mouseCursorPosition: point, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: point, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
        }
    }
}
