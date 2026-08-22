import AppKit
import CaptureKit
import CaptureKitSCK
import CoreGraphics
@preconcurrency import CoreImage
@preconcurrency import CoreVideo
@preconcurrency import ScreenCaptureKit

/// 连拍模式。
enum BurstMode {
    case burst        // 连拍：持续抓到松开或上限
    case fixedCount   // 定数：抓固定 N 张
    case timelapse    // 延时：按间隔抓
}

/// 连拍（Burst Capture）：像相机连拍一样快速抓多张屏幕截图。
///
/// 三种模式：连拍（持续）/ 定数（固定 N 张）/ 延时（按间隔）。
/// 技术：SCStream 持续推流，每收到一帧立即写盘 PNG（不在内存囤积，控制内存）。
/// 复用 ScreenRecordingManager 的 SCStream 模式，但输出是 PNG 序列而非视频。
@MainActor
final class BurstCaptureController: NSObject {
    static let shared = BurstCaptureController()

    // MARK: - 状态

    private(set) var isActive = false
    private(set) var isPaused = false
    private var isPreparing = false
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
    private var captureQueue = DispatchQueue(label: "com.tc.rune.burst", qos: .userInitiated)
    /// 延时拍摄循环任务（取代 DispatchSourceTimer——其回调在后台队列执行，
    /// 曾触发 Swift 6 隔离断言崩溃 dispatch_assert_queue；Task 循环天然在 MainActor）
    private var timelapseTask: Task<Void, Never>?
    private var startupWatchdogTask: Task<Void, Never>?
    private var singleShotEngine = SCKStillCaptureBackend()
    private var targetScreen: NSScreen?
    private var selectedDisplayID: CGDirectDisplayID?
    /// 连拍区域（CG 全局点坐标，nil=整屏）
    private var selectedRegion: CGRect?
    /// nonisolated 回调写入用（SCStreamOutput 回调从 captureQueue 来）。
    private var pendingStop = false
    /// 用户主动放弃时不进入结果整理台；已经写入的图片整组移到废纸篓。
    private var shouldDiscardOnEnd = false
    private var consecutiveCaptureFailures = 0
    private var failureMessage: String?
    /// 原子计数器：收帧回调从 captureQueue 来，用 NSLock 保护，避免跳 MainActor 的并发开销。
    /// nonisolated(unsafe)：用 frameLock 手动保护并发。
    private let frameLock = NSLock()
    private nonisolated(unsafe) var _frameIndex = 0
    private nonisolated(unsafe) var _isPaused = false
    /// 收帧回调所需的上下文（dir/limit/mode），在 start 时捕获，供 nonisolated 回调用。
    private struct BurstContext { let dir: URL?; let limit: Int; let mode: BurstMode }
    private nonisolated(unsafe) var burstContext: BurstContext?

    private override init() { super.init() }

    // MARK: - 启动

    /// 开始抓拍。
    /// - 连拍/定数：开 SCStream 持续收帧（region 非空时只推选区流）。
    /// - 延时：按间隔调 SCScreenshotManager 单帧截图（region 非空时逐张截选区）。
    /// - region：CG 全局点坐标（框选区域；nil = 整屏）
    func start(mode: BurstMode, on screen: NSScreen? = nil, region: CGRect? = nil) async {
        guard !isActive else { return }

        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .burst,
            on: screen
        ) else { return }

        isActive = true
        isPaused = false
        currentMode = mode
        capturedCount = 0
        pendingStop = false
        shouldDiscardOnEnd = false
        consecutiveCaptureFailures = 0
        failureMessage = nil
        selectedDisplayID = screen.flatMap { Self.displayID(for: $0) }
        targetScreen = screen
        selectedRegion = region   // CG 全局点坐标；推流走 sourceRect、延时走 .region
        frameLock.withLock {
            _frameIndex = 0
            _isPaused = false
        }

        // 每次连拍单独放进用户设置的截图目录，拍完不用钻进系统隐藏文件夹找。
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let sessionName = "Rune 连拍 \(formatter.string(from: Date()))"
        let base = URL(fileURLWithPath: AppPreferences.saveDirectory, isDirectory: true)
        var dir = base.appendingPathComponent(sessionName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = base.appendingPathComponent("\(sessionName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        outputDir = dir

        switch mode {
        case .burst, .fixedCount:
            await startStreamCapture(on: screen)
        case .timelapse:
            startTimelapseCapture(on: screen)
        }

        if isActive {
            startupWatchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.isActive, !self.isPaused, self.capturedCount == 0 else { return }
                self.failureMessage = "3 秒内没有抓到画面，请检查权限或选区"
                self.endCapture()
            }
        }
    }

    /// 停止抓拍（手动或达到上限时调）。
    func stop() {
        guard isActive else { return }
        pendingStop = true
        endCapture()
    }

    /// 暂停只停止写入新画面，已经拍到的图片原样保留；再次调用继续同一组连拍。
    func togglePause() {
        guard isActive else { return }
        isPaused.toggle()
        let paused = isPaused
        frameLock.withLock { _isPaused = paused }
    }

    /// 放弃当前这一组。为避免误删，文件进入废纸篓而不是永久删除。
    func discard() {
        guard isActive else { return }
        shouldDiscardOnEnd = true
        pendingStop = true
        endCapture()
    }

    /// 新流程入口：先框选区域（三合一：拖=区域/点窗=整窗/点桌面=全屏），
    /// 弹"开始控制台"（选模式），点开始才真正拍。region 随后喂给引擎。
    func prepareAndBegin(presetMode: BurstMode, on screen: NSScreen? = nil) async {
        guard !isPreparing else { return }
        guard !isActive else {
            // 已在拍：再次触发=停止
            stop()
            BurstLiveBarController.shared.dismiss()
            return
        }

        isPreparing = true
        defer { isPreparing = false }

        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .burst,
            on: screen
        ) else { return }

        let selection = await RegionSelectionOverlay().selectRegion()
        guard let selection else { return }   // Esc/右键取消

        let sizeText = "\(Int(selection.pointsRect.width))×\(Int(selection.pointsRect.height))"
        configureAndBegin(
            presetMode: presetMode,
            on: screen,
            region: selection.pointsRect,
            regionSizeText: sizeText
        )
    }

    /// 已经有选区时直接进入连拍准备面板。普通截图工具栏里的「连拍」走这里，
    /// 不会让用户再框一次同样的区域。
    func configureAndBegin(
        presetMode: BurstMode,
        on screen: NSScreen? = nil,
        region: CGRect,
        regionSizeText: String? = nil
    ) {
        let sizeText = regionSizeText ?? "\(Int(region.width))×\(Int(region.height))"
        let selectedRegion = region
        nonisolated(unsafe) let targetScreen = screen

        BurstSetupPanelController.shared.show(
            regionSizeText: sizeText,
            presetMode: presetMode,
            on: targetScreen
        ) { mode in
            Task {
                await self.start(mode: mode, on: targetScreen, region: selectedRegion)
                guard self.isActive else { return }
                BurstLiveBarController.shared.show(mode: mode, on: targetScreen) {
                    self.stop()
                }
            }
        }
    }

    // MARK: - 连拍/定数：SCStream

    private func startStreamCapture(on screen: NSScreen?) async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            print("Rune 连拍：获取内容失败 \(error)")
            failureMessage = "无法读取屏幕内容，请检查屏幕录制权限"
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
        if let region = selectedRegion {
            // 区域连拍：sourceRect 只推选区流（display 局部坐标）
            let clamped = region.intersection(display.frame)
            config.sourceRect = CGRect(
                x: clamped.minX - display.frame.minX,
                y: clamped.minY - display.frame.minY,
                width: clamped.width,
                height: clamped.height
            )
            config.width = Int(clamped.width * scale)
            config.height = Int(clamped.height * scale)
        } else {
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
        }
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
            print("Rune 连拍：addStreamOutput 失败 \(error)")
            failureMessage = "连拍引擎没有启动，请重试"
            endCapture()
            return
        }
        stream = scStream
        do { try await scStream.startCapture() }
        catch {
            print("Rune 连拍：startCapture 失败 \(error)")
            failureMessage = "连拍引擎没有启动，请重试"
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
                if self.isPaused {
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                }
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
            // 区域优先：逐张截选区；否则整屏/指定屏
            let target: CaptureTarget
            if let selectedRegion {
                target = .region(selectedRegion)
            } else {
                target = selectedDisplayID.map(CaptureTarget.display) ?? .fullscreen
            }
            let frame = try await singleShotEngine.capture(target)
            try writePNG(frame.image, to: dir, index: capturedCount + 1)
            capturedCount += 1
            consecutiveCaptureFailures = 0
        } catch {
            print("Rune 连拍：延时单帧失败 \(error)")
            noteCaptureFailure("连续三次没有抓到延时画面")
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
        let index: Int? = frameLock.withLock {
            guard !_isPaused, _frameIndex < limit else { return nil }
            _frameIndex += 1
            return _frameIndex
        }
        guard let index else { return }
        // 写盘（线程安全：每个文件名唯一，CGImageDestination 是栈上局部变量）
        let name = String(format: "连拍_%03d.png", index)
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            frameLock.withLock { _frameIndex = max(0, _frameIndex - 1) }
            Task { @MainActor in self.noteCaptureFailure("连续三次无法写入连拍图片") }
            return
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            frameLock.withLock { _frameIndex = max(0, _frameIndex - 1) }
            Task { @MainActor in self.noteCaptureFailure("连续三次无法写入连拍图片") }
            return
        }

        // 更新主线程计数 + 达上限检查
        let count = index
        Task { @MainActor in
            self.consecutiveCaptureFailures = 0
            self.capturedCount = count
            if count >= limit {
                self.endCapture()
            }
        }
    }

    // MARK: - 写盘

    private func writePNG(_ image: CGImage, to dir: URL, index: Int) throws {
        let name = String(format: "连拍_%03d.png", index)
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
        startupWatchdogTask?.cancel()
        startupWatchdogTask = nil
        // 收掉拍摄状态条，进入结果整理；不再突然弹 Finder 打断用户。
        BurstLiveBarController.shared.dismiss()

        let dir = outputDir
        let count = capturedCount
        let screen = targetScreen
        let discardsResults = shouldDiscardOnEnd
        let capturedFailureMessage = failureMessage
        burstContext = nil
        outputDir = nil
        shouldDiscardOnEnd = false
        failureMessage = nil
        consecutiveCaptureFailures = 0
        isPaused = false
        frameLock.withLock { _isPaused = false }

        if discardsResults {
            if let dir, FileManager.default.fileExists(atPath: dir.path) {
                do {
                    try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
                    ToastWindow.shared.show(
                        title: "已放弃连拍",
                        message: count > 0 ? "这组图片已移到废纸篓，可以恢复" : "没有保存任何图片",
                        systemIcon: "trash",
                        on: screen
                    )
                } catch {
                    ToastWindow.shared.show(
                        title: "无法移到废纸篓",
                        message: "图片仍保留在原文件夹中",
                        systemIcon: "exclamationmark.triangle",
                        on: screen
                    )
                }
            }
            targetScreen = nil
            return
        }

        if count > 0 {
            ToastWindow.shared.show(
                title: capturedFailureMessage == nil ? "连拍完成" : "连拍已提前结束",
                message: capturedFailureMessage.map { "\($0)；已保留 \(count) 张" }
                    ?? "已拍 \(count) 张，可以挑选、删除或导出",
                systemIcon: capturedFailureMessage == nil ? "camera.fill" : "exclamationmark.triangle",
                on: screen
            )
            if let dir {
                onComplete?(dir)
                BurstReviewWindowController.shared.show(directory: dir, on: screen)
            }
            print("Rune 连拍：结束，共抓 \(count) 张，输出到 \(dir?.path ?? "?")")
        } else {
            ToastWindow.shared.show(
                title: "连拍没有开始",
                message: capturedFailureMessage ?? "没有拍到画面，请检查屏幕录制权限后重试",
                systemIcon: "exclamationmark.triangle",
                on: screen
            )
            print("Rune 连拍：启动失败（可能屏幕录制权限未授或 SCStream 初始化失败），未抓到任何帧")
        }
        targetScreen = nil
    }

    private func noteCaptureFailure(_ message: String) {
        guard isActive else { return }
        consecutiveCaptureFailures += 1
        guard consecutiveCaptureFailures >= 3 else { return }
        failureMessage = message
        endCapture()
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
            print("Rune 连拍：流停止 \(error)")
            self.failureMessage = "屏幕捕获意外中断，已保留拍到的画面"
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
