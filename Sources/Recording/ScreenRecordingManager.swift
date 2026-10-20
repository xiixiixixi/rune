@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
import AppKit

/// SCStream 在后台线程回调，主界面在主线程启停录制。
/// 这个小盒子负责安全地转交当前录制会话，避免两个线程同时读写同一个变量。
private final class RecordingSessionSink: @unchecked Sendable {
    private let lock = NSLock()
    private var session: RecordingSession?

    func set(_ session: RecordingSession?) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let current = session
        lock.unlock()
        current?.appendVideoSample(sampleBuffer)
    }

    /// 扬声器（系统声音）
    func appendSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let current = session
        lock.unlock()
        current?.appendSystemAudioSample(sampleBuffer)
    }

    /// 麦克风（人声）。此前这个通道在代码里是空的——麦克风从来没真正接过。
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let current = session
        lock.unlock()
        current?.appendMicrophoneSample(sampleBuffer)
    }
}

@MainActor
@Observable
final class ScreenRecordingManager: NSObject {
    static let shared = ScreenRecordingManager()

    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case stopping
    }

    private(set) var state: State = .idle
    private(set) var elapsedSeconds: Int = 0

    /// 本次录制实际生效的选项（摄像头没设备时会与用户选的不一致）。
    private(set) var activeOptions = RecordingOptions()

    private var stream: SCStream?
    private var session: RecordingSession?
    private var outputURL: URL?
    private var timer: Timer?
    private var cameraProvider: CameraFrameProvider?
    private var clickTracker: MouseClickTracker?
    private var clickMapping: CaptureFrameMapping?
    nonisolated private let streamSessionSink = RecordingSessionSink()

    private let videoQueue = DispatchQueue(label: "com.tc.rune.recording.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.tc.rune.recording.audio", qos: .userInteractive)
    private let microphoneQueue = DispatchQueue(label: "com.tc.rune.recording.microphone", qos: .userInteractive)

    private override init() { super.init() }

    var isRecording: Bool { state == .recording || state == .paused }

    // MARK: - 能力探测

    /// 麦克风通道需要 macOS 15 起的 ScreenCaptureKit 麦克风输出。
    nonisolated static var supportsMicrophoneCapture: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 鼠标点击高亮同理（SCK 的 showMouseClicks）。
    nonisolated static var supportsClickHighlight: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    /// 系统里有没有可用的麦克风输入设备。
    nonisolated static var microphoneDeviceAvailable: Bool {
        AVCaptureDevice.default(for: .audio) != nil
    }

    /// 申请麦克风权限（与摄像头同一套预检逻辑）。
    nonisolated static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - Start

    func startRecording(on screen: NSScreen? = nil) async throws -> Bool {
        return try await startFullScreenRecording(on: screen)
    }

    func startFullScreenRecording(
        on screen: NSScreen? = nil,
        options: RecordingOptions = .fromPreferences()
    ) async throws -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        defer {
            if state == .preparing { resetAfterFailedStart() }
        }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .recording,
            on: screen
        ) else { return false }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let requestedID = screen.flatMap { Self.displayID(for: $0) }
        guard let display = requestedID.flatMap({ id in content.displays.first { $0.displayID == id } })
                ?? content.displays.first else {
            state = .idle
            return false
        }

        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let contentRect = filter.contentRect
        let pointPixelScale = CGFloat(filter.pointPixelScale)
        let captureWidth = Int(contentRect.width * pointPixelScale)
        let captureHeight = Int(contentRect.height * pointPixelScale)

        do {
            return try await beginCapture(
                filter: filter,
                width: captureWidth,
                height: captureHeight,
                options: options,
                mapping: CaptureFrameMapping(
                    regionOrigin: display.frame.origin,
                    regionSize: display.frame.size,
                    pixelSize: CGSize(width: captureWidth, height: captureHeight)
                )
            )
        } catch {
            resetAfterFailedStart()
            throw error
        }
    }

    func startAreaRecording(
        on screen: NSScreen? = nil,
        options: RecordingOptions = .fromPreferences()
    ) async throws -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        defer {
            if state == .preparing { resetAfterFailedStart() }
        }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .recording,
            on: screen
        ) else { return false }

        let overlay = RegionSelectionOverlay()
        guard let selection = await overlay.selectRegion(initialMode: .recording) else { return false }
        return try await startAreaRecording(selection: selection, on: screen, options: options)
    }

    /// 已经选好区域时直接开录：主入口的模式条把"录屏"选上时走这条路径，
    /// 不必再弹一次选区。
    func startAreaRecording(
        selection: RegionSelection,
        on screen: NSScreen? = nil,
        options: RecordingOptions = .fromPreferences()
    ) async throws -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        defer {
            if state == .preparing { resetAfterFailedStart() }
        }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .recording,
            on: screen
        ) else { return false }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let center = CGPoint(x: selection.pointsRect.midX, y: selection.pointsRect.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
                ?? content.displays.first else {
            state = .idle
            return false
        }

        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        let excludedApps = content.applications.filter { $0.bundleIdentifier == ownBundleID }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let pointPixelScale = filter.pointPixelScale
        let clamped = selection.pointsRect.intersection(display.frame)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else {
            state = .idle
            return false
        }
        let mappedSourceRect = CGRect(
            x: clamped.minX - display.frame.minX,
            y: clamped.minY - display.frame.minY,
            width: clamped.width,
            height: clamped.height
        )

        let scale = CGFloat(pointPixelScale)
        let captureWidth = Int(clamped.width * scale)
        let captureHeight = Int(clamped.height * scale)

        do {
            return try await beginCapture(
                filter: filter,
                width: captureWidth,
                height: captureHeight,
                options: options,
                sourceRect: mappedSourceRect,
                mapping: CaptureFrameMapping(
                    regionOrigin: clamped.origin,
                    regionSize: clamped.size,
                    pixelSize: CGSize(width: captureWidth, height: captureHeight)
                )
            )
        } catch {
            resetAfterFailedStart()
            throw error
        }
    }

    private func beginCapture(
        filter: SCContentFilter,
        width: Int,
        height: Int,
        options: RecordingOptions,
        sourceRect: CGRect? = nil,
        mapping: CaptureFrameMapping? = nil
    ) async throws -> Bool {
        // 摄像头（画中画）：先起摄像头，录制的第一帧就带着画面。
        var camera: CameraFrameProvider?
        var effectiveOptions = options
        if options.captureCamera {
            let availability = CameraFrameProvider.availability()
            if !availability.isUsable {
                effectiveOptions.captureCamera = false
                ToastWindow.shared.show(
                    title: "摄像头不可用",
                    message: availability.reason ?? "无法打开摄像头",
                    systemIcon: "video.slash"
                )
            } else {
                let granted = await CameraFrameProvider.requestAccess()
                guard granted else {
                    effectiveOptions.captureCamera = false
                    ToastWindow.shared.show(
                        title: "摄像头不可用",
                        message: "尚未授权摄像头访问",
                        systemIcon: "video.slash"
                    )
                    return false
                }
                let provider = CameraFrameProvider()
                do {
                    try provider.start()
                    camera = provider
                } catch {
                    effectiveOptions.captureCamera = false
                    ToastWindow.shared.show(
                        title: "摄像头不可用",
                        message: error.localizedDescription,
                        systemIcon: "video.slash"
                    )
                }
            }
        }
        cameraProvider = camera

        if options.captureMicrophone {
            // 麦克风必须先做预检：设备在不在、有没有授权。
            // 没有麦克风的机器上只要把麦克风通道打开，ScreenCaptureKit 就起不来，
            // 表现为「点了开始录制之后什么都没发生」——必须提前挡掉。
            if !Self.microphoneDeviceAvailable {
                effectiveOptions.captureMicrophone = false
                ToastWindow.shared.show(
                    title: "麦克风不可用",
                    message: "此设备没有麦克风",
                    systemIcon: "mic.slash"
                )
            } else {
                let granted = await Self.requestMicrophoneAccess()
                guard granted else {
                    effectiveOptions.captureMicrophone = false
                    ToastWindow.shared.show(
                        title: "麦克风不可用",
                        message: "尚未授权麦克风访问",
                        systemIcon: "mic.slash"
                    )
                    return false
                }
            }
        }

        // 预检都过了再落地「实际生效的选项」，面板与状态栏显示的就是它。
        activeOptions = effectiveOptions

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height

        if let sourceRect {
            config.sourceRect = sourceRect
        }
        let fps = effectiveOptions.fps
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = effectiveOptions.showCursor

        // 扬声器（系统声音）
        if effectiveOptions.captureSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }

        if #available(macOS 15.0, *) {
            // 鼠标点击高亮：自己画（见 MouseClickTracker）。
            // 系统自带的 showMouseClicks 实测不会出现在录出来的画面里，
            // 两套同时开反而可能出现两个圈，所以系统那个关掉。
            config.showMouseClicks = false
            // 麦克风：独立于扬声器的另一条通道。
            config.captureMicrophone = effectiveOptions.captureMicrophone
        }

        // 鼠标点击高亮：起一个全局监听记录点击位置，画圈由合成器完成。
        var clickTracker: MouseClickTracker?
        if effectiveOptions.highlightMouseClicks, let mapping {
            let tracker = MouseClickTracker()
            tracker.start()
            clickTracker = tracker
            self.clickMapping = mapping
        } else {
            self.clickMapping = nil
        }
        self.clickTracker = clickTracker

        let dir = AppPreferences.saveDirectory
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let path = "\(dir)/录屏_\(stamp).mp4"
        let url = URL(fileURLWithPath: path)
        outputURL = url

        let recordingSession = try RecordingSession(
            outputURL: url,
            width: width,
            height: height,
            fps: fps,
            includeSystemAudio: effectiveOptions.captureSystemAudio,
            includeMicrophone: effectiveOptions.captureMicrophone,
            cameraProvider: camera,
            clickTracker: clickTracker,
            clickMapping: clickMapping
        )

        guard await recordingSession.startWriting() else {
            state = .idle
            return false
        }

        self.session = recordingSession
        streamSessionSink.set(recordingSession)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if effectiveOptions.captureSystemAudio {
            // 加不上的通道不能让整个录制失败（没有音频设备时就会这样）：
            // 跳过这一路，录屏照常。
            try? scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        if effectiveOptions.captureMicrophone, Self.supportsMicrophoneCapture {
            // 麦克风输出是 macOS 15 起才有的，低版本自动跳过（扬声器照常）。
            if #available(macOS 15.0, *) {
                try? scStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: microphoneQueue)
            }
        }

        self.stream = scStream

        // 起流也可能被麦克风通道拖住（设备在、但系统那头起不来），
        // 所以这里加个超时：起不来就退回「不带麦克风」重开一次。
        do {
            try await Self.startCapture(scStream, timeout: 8)
        } catch where effectiveOptions.captureMicrophone {
            try? await scStream.stopCapture()
            if #available(macOS 15.0, *) {
                try? scStream.removeStreamOutput(self, type: .microphone)
            }
            resetAfterFailedStart()

            effectiveOptions.captureMicrophone = false
            activeOptions = effectiveOptions
            ToastWindow.shared.show(
                title: "麦克风不可用",
                message: "麦克风通道起不来，已改为只录扬声器",
                systemIcon: "mic.slash"
            )
            return try await beginCapture(
                filter: filter,
                width: width,
                height: height,
                options: effectiveOptions,
                sourceRect: sourceRect
            )
        }

        recordingSession.isCapturing = true

        state = .recording
        elapsedSeconds = 0
        startTimer()

        return true
    }

    /// 启动采集流。带超时保护：麦克风通道起不来时不会无限期挂着。
    private static func startCapture(_ stream: SCStream, timeout: Double) async throws {
        let box = StreamStartBox()
        let starter = Task {
            do {
                try await stream.startCapture()
                box.finish(.success(()))
            } catch {
                box.finish(.failure(error))
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !box.isDone, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(80))
        }
        if !box.isDone {
            starter.cancel()
            throw StreamStartError.timedOut
        }
        guard case .failure(let error) = box.outcome else { return }
        throw error
    }

    enum StreamStartError: LocalizedError {
        case timedOut
        var errorDescription: String? { "采集流启动超时" }
    }

    /// 采集流启动结果（跨线程回传）
    private final class StreamStartBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        var isDone: Bool { lock.withLock { result != nil } }
        func finish(_ value: Result<Void, Error>) {
            lock.lock()
            result = value
            lock.unlock()
        }
        var outcome: Result<Void, Error>? { lock.withLock { result } }
    }

    private func resetAfterFailedStart() {
        session?.cancelWriting()
        session = nil
        streamSessionSink.set(nil)
        stream = nil
        cameraProvider?.stop()
        cameraProvider = nil
        clickTracker?.stop()
        clickTracker = nil
        clickMapping = nil
        if let outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        outputURL = nil
        state = .idle
        elapsedSeconds = 0
    }

    // MARK: - Stop

    func stopRecording() async -> URL? {
        guard isRecording, state != .stopping else { return nil }
        state = .stopping
        stopTimer()

        session?.isCapturing = false

        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            if #available(macOS 15.0, *) {
                try? stream.removeStreamOutput(self, type: .microphone)
            }
            try? await stream.stopCapture()
        }
        stream = nil

        session?.finishInputs()
        await session?.finishWriting()
        session = nil
        streamSessionSink.set(nil)
        cameraProvider?.stop()
        cameraProvider = nil

        state = .idle
        elapsedSeconds = 0

        let url = outputURL
        outputURL = nil
        return url
    }

    // MARK: - Pause / Resume

    func pauseRecording() {
        guard state == .recording else { return }
        session?.isCapturing = false
        state = .paused
        stopTimer()
    }

    func resumeRecording() {
        guard state == .paused else { return }
        session?.isCapturing = true
        state = .recording
        startTimer()
    }

    func togglePause() {
        if state == .recording { pauseRecording() }
        else if state == .paused { resumeRecording() }
    }

    // MARK: - Cancel

    func cancelRecording() async {
        guard (isRecording || state == .preparing) && state != .stopping else { return }
        stopTimer()
        session?.isCapturing = false

        if let stream {
            try? stream.removeStreamOutput(self, type: .screen)
            try? stream.removeStreamOutput(self, type: .audio)
            if #available(macOS 15.0, *) {
                try? stream.removeStreamOutput(self, type: .microphone)
            }
            try? await stream.stopCapture()
        }
        stream = nil

        session?.cancelWriting()
        session = nil
        streamSessionSink.set(nil)
        cameraProvider?.stop()
        cameraProvider = nil

        if let url = outputURL {
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil

        state = .idle
        elapsedSeconds = 0
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecordingManager: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            if self.isRecording {
                _ = await self.stopRecording()
            }
        }
    }
}

// MARK: - SCStreamOutput

extension ScreenRecordingManager: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            guard sampleBuffer.isValid else { return }
            streamSessionSink.appendVideo(sampleBuffer)
        case .audio:
            // 扬声器：系统 / 应用声音
            streamSessionSink.appendSystemAudio(sampleBuffer)
        case .microphone:
            // 麦克风：人声，与扬声器各自独立成轨
            streamSessionSink.appendMicrophone(sampleBuffer)
        @unknown default:
            break
        }
    }
}
