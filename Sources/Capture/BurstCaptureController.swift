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
    private var captureQueue = DispatchQueue(label: "com.tc.qingjie.burst", qos: .userInitiated)
    /// 延时拍摄循环任务（取代 DispatchSourceTimer——其回调在后台队列执行，
    /// 曾触发 Swift 6 隔离断言崩溃 dispatch_assert_queue；Task 循环天然在 MainActor）
    private var timelapseTask: Task<Void, Never>?
    private var singleShotEngine = SCKStillCaptureBackend()
    private var selectedDisplayID: CGDirectDisplayID?
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

        // 权限处理：用系统 API 请求（触发系统弹框），而不是自己弹自定义框。
        // CGPreflightScreenCaptureAccess 只检查不请求；CGRequestScreenCaptureAccess 会触发系统弹框。
        if !CGPreflightScreenCaptureAccess() {
            // 主动请求权限——系统会弹出“轻截想要录制屏幕”的系统级对话框
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                let alert = NSAlert()
                alert.messageText = "需要屏幕录制权限"
                alert.informativeText = "请在系统设置的「隐私与安全性 > 屏幕与系统音频录制」中允许“轻截”，然后重新打开轻截。"
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
            // 请求后不继续（用户需要去授权，下次再按才会真正截图）
            return
        }

        isActive = true
        currentMode = mode
        capturedCount = 0
        pendingStop = false
        selectedDisplayID = screen.flatMap { Self.displayID(for: $0) }
        frameLock.withLock { _frameIndex = 0 }

        // 创建输出文件夹：~/Library/Application Support/轻截/连续截图/<时间戳>/
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
        let requestedDisplayID = screen.flatMap { Self.displayID(for: $0) }
        guard let display = requestedDisplayID.flatMap({ id in content.displays.first { $0.displayID == id } })
                ?? content.displays.first else {
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
        // 延时用单帧截图（SCScreenshotManager），不需要持续推流。
        // Task 循环取代 DispatchSourceTimer：在 @MainActor 方法里创建的 Task
        // 继承 MainActor 上下文，sleep/恢复都在正确执行器，无隔离断言风险。
        let interval = timelapseInterval
        let limit = timelapseLimit
        timelapseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                await self.captureOneTimelapseFrame()
                if self.capturedCount >= limit {
                    self.endCapture()
                    return
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func captureOneTimelapseFrame() async {
        guard let dir = outputDir else { return }
        do {
            let target = selectedDisplayID.map(CaptureTarget.display) ?? .fullscreen
            let frame = try await singleShotEngine.capture(target)
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
        let name = String(format: "连续截图_%03d.png", index)
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
        let name = String(format: "连续截图_%03d.png", index)
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
        timelapseTask?.cancel()
        timelapseTask = nil

        let dir = outputDir
        let count = capturedCount

        if count > 0 {
            // 抓到了图：回调 + 在 Finder 打开输出文件夹
            if let dir {
                onComplete?(dir)
                NSWorkspace.shared.open(dir)
            }
            print("金手指：结束，共抓 \(count) 张，输出到 \(dir?.path ?? "?")")
        } else {
            // 一张都没抓到：SCStream 启动失败或权限问题，不弹 Finder
            print("金手指：启动失败（可能屏幕录制权限未授或 SCStream 初始化失败），未抓到任何帧")
        }
    }

    // MARK: - 输出目录

    private var burstBaseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("轻截/连续截图", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
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
