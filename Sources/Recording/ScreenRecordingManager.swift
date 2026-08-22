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

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let current = session
        lock.unlock()
        current?.appendAudioSample(sampleBuffer)
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

    private var stream: SCStream?
    private var session: RecordingSession?
    private var outputURL: URL?
    private var timer: Timer?
    nonisolated private let streamSessionSink = RecordingSessionSink()

    private let videoQueue = DispatchQueue(label: "com.tc.rune.recording.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.tc.rune.recording.audio", qos: .userInteractive)

    private override init() { super.init() }

    var isRecording: Bool { state == .recording || state == .paused }

    // MARK: - Start

    func startRecording(on screen: NSScreen? = nil) async throws -> Bool {
        return try await startFullScreenRecording(on: screen)
    }

    func startFullScreenRecording(on screen: NSScreen? = nil) async throws -> Bool {
        guard state == .idle else { return false }
        state = .preparing
        defer {
            if state == .preparing { resetAfterFailedStart() }
        }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .recording,
            on: screen
        ) else { return false }

        let captureAudio = AppPreferences.recordingCaptureAudio
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
                captureAudio: captureAudio
            )
        } catch {
            resetAfterFailedStart()
            throw error
        }
    }

    func startAreaRecording(on screen: NSScreen? = nil) async throws -> Bool {
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
        guard let selection = await overlay.selectRegion() else { return false }

        let captureAudio = AppPreferences.recordingCaptureAudio
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
                captureAudio: captureAudio,
                sourceRect: mappedSourceRect
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
        captureAudio: Bool,
        sourceRect: CGRect? = nil
    ) async throws -> Bool {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height

        if let sourceRect {
            config.sourceRect = sourceRect
        }
        let fps = AppPreferences.recordingFPS
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 5
        config.showsCursor = AppPreferences.recordingShowCursor

        if captureAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
        }

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
            includeAudio: captureAudio
        )

        guard recordingSession.startWriting() else {
            state = .idle
            return false
        }

        self.session = recordingSession
        streamSessionSink.set(recordingSession)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if captureAudio {
            try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }

        self.stream = scStream

        try await scStream.startCapture()
        recordingSession.isCapturing = true

        state = .recording
        elapsedSeconds = 0
        startTimer()

        return true
    }

    private func resetAfterFailedStart() {
        session?.cancelWriting()
        session = nil
        streamSessionSink.set(nil)
        stream = nil
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
            try? await stream.stopCapture()
        }
        stream = nil

        session?.finishInputs()
        await session?.finishWriting()
        session = nil
        streamSessionSink.set(nil)

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
            try? await stream.stopCapture()
        }
        stream = nil

        session?.cancelWriting()
        session = nil
        streamSessionSink.set(nil)

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
            streamSessionSink.appendAudio(sampleBuffer)
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}
