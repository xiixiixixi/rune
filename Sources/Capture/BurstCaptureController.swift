import AppKit
import CaptureKit
import CaptureKitSCK
import CoreGraphics
import CoreImage
import CoreVideo
import ScreenCaptureKit

/// 金手指模式。
enum BurstMode {
    case burst        // 连拍：持续抓到松开或上限
    case fixedCount   // 定数：抓固定 N 张
    case timelapse    // 延时：按间隔抓
}

/// 金手指（Burst Capture）：像相机连拍一样快速抓多张屏幕截图。
///
/// 三种模式：连拍（持续）/ 定数（固定 N 张）/ 延时（按间隔）。
/// 技术：SCStream 持续推流，每收到一帧立即写盘 PNG（不在内存囤积，控制内存）。
/// 复用 ScreenRecordingManager 的 SCStream 模式，但输出是 PNG 序列而非视频。
@MainActor
final class BurstCaptureController: NSObject {
    static let shared = BurstCaptureController()

    // MARK: - 状态

    private(set) var isActive = false
    private(set) var capturedCount = 0
    private(set) var currentMode: BurstMode = .burst

    /// 抓完后回调（输出文件夹 URL）。
    var onComplete: ((URL) -> Void)?

    // MARK: - 配置（连拍/定数用）

    /// 帧率（FPS）：10/15/30 可选。
    var fps: Int = 10
    /// 连拍模式上限（防内存/磁盘爆）。
    var burstLimit = 60
    /// 定数模式的张数。
    var fixedCount = 10
    /// 延时模式的间隔（秒）。
    var timelapseInterval: TimeInterval = 5
    /// 延时模式上限。
    var timelapseLimit = 100

    // MARK: - 私有

    private var stream: SCStream?
    private var outputDir: URL?
    private var captureQueue = DispatchQueue(label: "bettershot.burst", qos: .userInitiated)
    private var timelapseTimer: DispatchSourceTimer?
    private var singleShotEngine = SCKStillCaptureBackend()
    /// nonisolated 回调写入用（SCStreamOutput 回调从 captureQueue 来）。
    private var pendingStop = false
    /// 原子计数器：收帧回调从 captureQueue 来，用 NSLock 保护，避免跳 MainActor 的并发开销。
    /// nonisolated(unsafe)：用 frameLock 手动保护并发。
    private let frameLock = NSLock()
    private nonisolated(unsafe) var _frameIndex = 0
    /// 收帧回调所需的上下文（dir/limit/mode），在 start 时捕获，供 nonisolated 回调用。
    private struct BurstContext { let dir: URL?; let limit: Int; let mode: BurstMode }
    private nonisolated(unsafe) var burstContext: BurstContext?

    private override init() { super.init() }

    // MARK: - 启动

    /// 开始抓拍。
    /// - 连拍/定数：开 SCStream 持续收帧。
    /// - 延时：按间隔调 SCScreenshotManager 单帧截图（延时不需要高帧率）。
    func start(mode: BurstMode, on screen: NSScreen? = nil) async {
        guard !isActive else { return }
        isActive = true
        currentMode = mode
        capturedCount = 0
        pendingStop = false
        frameLock.withLock { _frameIndex = 0 }

        // 创建输出文件夹：~/Library/Application Support/BetterShot/bursts/<时间戳>/
        let stamp = Int(Date().timeIntervalSince1970)
        let dir = burstBaseDir.appendingPathComponent("\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outputDir = dir

        switch mode {
        case .burst, .fixedCount:
            await startStreamCapture(on: screen)
        case .timelapse:
            startTimelapseCapture(on: screen)
        }
    }

    /// 停止抓拍（手动或达到上限时调）。
    func stop() {
        guard isActive else { return }
        pendingStop = true
        endCapture()
    }

    // MARK: - 连拍/定数：SCStream

    private func startStreamCapture(on screen: NSScreen?) async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("金手指：获取内容失败 \(error)")
            endCapture()
            return
        }
        guard let display = content.displays.first else {
            endCapture()
            return
        }
        let myBundleID = Bundle.main.bundleIdentifier ?? ""
        let excludedApps = content.applications.filter { $0.bundleIdentifier == myBundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = false

        // 捕获回调所需参数到局部（回调从 captureQueue 来，不访问 @MainActor 状态）
        let dir = outputDir
        let limit = (currentMode == .fixedCount) ? fixedCount : burstLimit
        let mode = currentMode
        burstContext = BurstContext(dir: dir, limit: limit, mode: mode)

        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        } catch {
            print("金手指：addStreamOutput 失败 \(error)")
            endCapture()
            return
        }
        stream = scStream
        do { try await scStream.startCapture() }
        catch {
            print("金手指：startCapture 失败 \(error)")
            endCapture()
        }
    }

    // MARK: - 延时：定时单帧

    private func startTimelapseCapture(on screen: NSScreen?) {
        // 延时用单帧截图（SCScreenshotManager），不需要持续推流
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now(), repeating: timelapseInterval)
        let interval = timelapseInterval
        let limit = timelapseLimit
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                await self.captureOneTimelapseFrame()
                if self.capturedCount >= limit {
                    self.endCapture()
                }
            }
        }
        timer.resume()
        timelapseTimer = timer
        _ = interval  // 保留参数引用
    }

    private func captureOneTimelapseFrame() async {
        guard let dir = outputDir else { return }
        do {
            let frame = try await singleShotEngine.capture(CaptureTarget.fullscreen)
            try writePNG(frame.image, to: dir, index: capturedCount + 1)
            capturedCount += 1
        } catch {
            print("金手指：延时单帧失败 \(error)")
        }
    }

    // MARK: - 收帧（从 captureQueue 来，用锁保护，不跳 MainActor）

    /// 把 CMSampleBuffer 转 CGImage 并写盘。每帧立即写、立即释放，控制内存。
    /// 在 captureQueue 上执行（nonisolated），用 frameLock 保护计数。
    nonisolated private func handleFrame(_ sampleBuffer: CMSampleBuffer, dir: URL, limit: Int, mode: BurstMode) {
        guard sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        // 加锁取序号
        let index: Int = frameLock.withLock {
            _frameIndex += 1
            return _frameIndex
        }
        // 写盘（线程安全：每个文件名唯一，CGImageDestination 是栈上局部变量）
        let name = String(format: "burst_%03d.png", index)
        let url = dir.appendingPathComponent(name)
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            _ = CGImageDestinationFinalize(dest)
        }

        // 更新主线程计数 + 达上限检查
        let count = index
        Task { @MainActor in
            self.capturedCount = count
            if count >= limit {
                self.endCapture()
            }
        }
    }

    // MARK: - 写盘

    private func writePNG(_ image: CGImage, to dir: URL, index: Int) throws {
        let name = String(format: "burst_%03d.png", index)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "BurstCapture", code: 1)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "BurstCapture", code: 2)
        }
    }

    // MARK: - 结束

    private func endCapture() {
        guard isActive else { return }
        isActive = false

        // 停 SCStream
        if let stream {
            Task { try? await stream.stopCapture() }
            self.stream = nil
        }
        // 停延时定时器
        timelapseTimer?.cancel()
        timelapseTimer = nil

        let dir = outputDir
        let count = capturedCount
        // 回调 + 在 Finder 打开
        if let dir {
            onComplete?(dir)
            NSWorkspace.shared.open(dir)
        }
        print("金手指：结束，共抓 \(count) 张，输出到 \(dir?.path ?? "?")")
    }

    // MARK: - 输出目录

    private var burstBaseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BetterShot/bursts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - SCStreamDelegate & Output

extension BurstCaptureController: SCStreamDelegate, SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            print("金手指：流停止 \(error)")
            self.endCapture()
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let ctx = burstContext, let dir = ctx.dir else { return }
        // 在 captureQueue 上直接处理帧（写盘线程安全），不跳 MainActor，避免并发开销。
        handleFrame(sampleBuffer, dir: dir, limit: ctx.limit, mode: ctx.mode)
    }
}
