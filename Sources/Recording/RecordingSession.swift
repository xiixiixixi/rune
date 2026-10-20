@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import CoreVideo

/// 录制写入端。
///
/// 音频是**两条独立音轨**：扬声器（系统声音）与麦克风（人声）。
/// 两条轨各自先规范化成同一格式再进写入器——格式不一致的话，
/// 播放器混音和导出都会出问题（飞书的录屏面板也是分开控制的）。
final class RecordingSession: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// 系统音频轨（扬声器）
    private let systemAudioInput: AVAssetWriterInput?
    /// 麦克风轨
    private let microphoneInput: AVAssetWriterInput?
    private let systemAudioNormalizer = AudioSampleNormalizer()
    private let microphoneNormalizer = AudioSampleNormalizer()

    /// 画中画合成器（不开摄像头、不点鼠标时为 nil）
    private let compositor: RecordingFrameCompositor?
    private let cameraProvider: CameraFrameProvider?
    /// 鼠标点击追踪（开了点击高亮时非 nil）
    private let clickTracker: MouseClickTracker?
    private let clickMapping: CaptureFrameMapping?

    private let lock = NSLock()
    private var _isCapturing = false
    private var _firstTimestamp: CMTime?
    private var _sessionStarted = false

    /// 写入器刚启动时输入还没就绪，那几帧如果直接丢掉，
    /// 成片开头就会缺一小段。这里先攒着，等就绪了按顺序补上。
    private var pendingFrames: [(buffer: CVPixelBuffer, timestamp: CMTime)] = []
    private let maxPendingFrames = 8

    /// 统计：写入器实际拒绝/失败时能看到（验收用）。
    private(set) var droppedAudioSamples: Int = 0
    private(set) var writtenAudioSamples: Int = 0

    var isCapturing: Bool {
        get { lock.withLock { _isCapturing } }
        set { lock.withLock { _isCapturing = newValue } }
    }

    init(
        outputURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        includeSystemAudio: Bool,
        includeMicrophone: Bool,
        cameraProvider: CameraFrameProvider? = nil,
        clickTracker: MouseClickTracker? = nil,
        clickMapping: CaptureFrameMapping? = nil
    ) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * fps * 4,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ] as [String: Any],
        ]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        writer.add(videoInput)

        // 音轨参数与 AudioSampleConverter.canonicalFormat 一致：
        // 48kHz / 双声道。
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]

        if includeSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemAudioInput = input
        } else {
            systemAudioInput = nil
        }

        if includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            microphoneInput = input
        } else {
            microphoneInput = nil
        }

        if cameraProvider != nil || clickTracker != nil {
            let compositor = RecordingFrameCompositor()
            compositor.prepare(width: width, height: height)
            self.compositor = compositor
        } else {
            compositor = nil
        }
        self.cameraProvider = cameraProvider
        self.clickTracker = clickTracker
        self.clickMapping = clickMapping
    }

    /// 启动写入器，并且**等到视频输入就绪**再返回。
    ///
    /// 不等的话，写入器刚起来的那几十毫秒里输入还没就绪，
    /// 头几帧会被直接丢掉——成片开头缺一小段，而且这种缺失很难被察觉。
    func startWriting() async -> Bool {
        writer.startWriting()
        guard writer.status == .writing else { return false }
        for _ in 0..<100 {
            if videoInput.isReadyForMoreMediaData { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return writer.status == .writing
    }

    func appendVideoSample(_ sampleBuffer: CMSampleBuffer) {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let shouldStartSession: Bool

        lock.lock()
        guard _isCapturing else { lock.unlock(); return }
        if !_sessionStarted {
            _firstTimestamp = timestamp
            _sessionStarted = true
            shouldStartSession = true
        } else {
            shouldStartSession = false
        }
        lock.unlock()

        if shouldStartSession {
            writer.startSession(atSourceTime: timestamp)
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 当前还在显示的点击高亮圈（没有点击时这里是空数组，合成器会直接透传）
        var clicks: [RecordingFrameCompositor.ClickMark] = []
        if let clickTracker, let clickMapping {
            let now = CACurrentMediaTime()
            for mark in clickTracker.recentMarks() {
                guard let pixel = clickMapping.pixel(for: mark.point) else { continue }
                clicks.append(
                    RecordingFrameCompositor.ClickMark(point: pixel, age: now - mark.timestamp)
                )
            }
        }

        var output = pixelBuffer
        let cameraFrame = cameraProvider?.latestFrame
        if let compositor, cameraFrame != nil || !clicks.isEmpty {
            output = compositor.render(
                screen: pixelBuffer,
                camera: cameraFrame,
                clicks: clicks,
                cameraRotation: cameraProvider?.rotationAngle ?? 0
            )
        }

        guard videoInput.isReadyForMoreMediaData else {
            // 输入还没就绪：先攒着，别把开头的帧丢了。
            lock.lock()
            pendingFrames.append((output, timestamp))
            if pendingFrames.count > maxPendingFrames {
                pendingFrames.removeFirst()
            }
            lock.unlock()
            return
        }

        // 先把之前攒下的帧按顺序补上，再写当前帧。
        lock.lock()
        let backlog = pendingFrames
        pendingFrames.removeAll()
        lock.unlock()
        for item in backlog {
            adaptor.append(item.buffer, withPresentationTime: item.timestamp)
        }
        adaptor.append(output, withPresentationTime: timestamp)
    }

    /// 扬声器（系统声音）
    func appendSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        appendAudioSample(sampleBuffer, to: systemAudioInput, normalizer: systemAudioNormalizer)
    }

    /// 麦克风（人声）
    func appendMicrophoneSample(_ sampleBuffer: CMSampleBuffer) {
        appendAudioSample(sampleBuffer, to: microphoneInput, normalizer: microphoneNormalizer)
    }

    private func appendAudioSample(
        _ sampleBuffer: CMSampleBuffer,
        to input: AVAssetWriterInput?,
        normalizer: AudioSampleNormalizer
    ) {
        lock.lock()
        guard _isCapturing, _sessionStarted else { lock.unlock(); return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard let first = _firstTimestamp, timestamp >= first else { lock.unlock(); return }

        lock.unlock()

        guard let input else { return }
        guard input.isReadyForMoreMediaData else {
            lock.lock(); droppedAudioSamples += 1; lock.unlock()
            return
        }
        guard let normalized = normalizer.canonicalize(sampleBuffer) else {
            lock.lock(); droppedAudioSamples += 1; lock.unlock()
            return
        }
        input.append(normalized)
        lock.lock(); writtenAudioSamples += 1; lock.unlock()
    }

    func finishInputs() {
        // 收尾前把还攒着的帧补上（就绪的话），别让结尾也缺一截。
        if videoInput.isReadyForMoreMediaData {
            lock.lock()
            let backlog = pendingFrames
            pendingFrames.removeAll()
            lock.unlock()
            for item in backlog {
                adaptor.append(item.buffer, withPresentationTime: item.timestamp)
            }
        }
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
    }

    func finishWriting() async {
        await writer.finishWriting()
    }

    func cancelWriting() {
        writer.cancelWriting()
    }

    /// 写入器最终的错误（验收用：失败时要能说出原因，而不是"文件没出来"）。
    var writerError: String? {
        guard writer.status == .failed, let error = writer.error else { return nil }
        return error.localizedDescription
    }

    var writerStatus: String { String(describing: writer.status) }
}
