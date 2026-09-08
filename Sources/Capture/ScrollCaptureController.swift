import AppKit
import CaptureKit
import CaptureKitSCK
import ImageIO
import OSLog
import SwiftUI
@preconcurrency import Vision

// 滚动配准核心（滚动条列/吸顶行检测、全帧 Vision 配准、整帧近乎相同拒绝、
// 逐字节稳定帧、最少新内容行数校验、帧数预算、收尾补帧）移植自 capcap：
// https://github.com/realskyrin/capcap （MIT License, Copyright capcap authors）。
// 双向拼接、区间跟踪与重复条带闸门为 Rune 自有实现。

enum ScrollCaptureMode: String {
    case automatic
    case manual

    var label: String {
        switch self {
        case .automatic: return "自动"
        case .manual: return "手动"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: return "arrow.down.to.line.compact"
        case .manual: return "hand.draw"
        }
    }
}

/// 滚动截图：框选滚动内容后手动滚动（默认，兼容性最高——飞书同款路线），
/// 授权辅助功能后可切换为自动注入滚轮的增强模式。
///
/// 拼接遵循钉钉/飞书的通用做法：相邻帧找重叠 → 只追加真正新出现的内容。
/// 支持**双向**：向下滚追加到底部，向上滚（聊天记录补历史）插入顶部；
/// 区间跟踪（ScrollRangeTracker）保证来回滚动绝不重复拼接。
@MainActor
@Observable
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tc.rune",
        category: "ScrollCapture"
    )

    private(set) var isActive = false
    private var isPreparing = false
    private(set) var capturedFrameCount = 0
    private(set) var stitchedHeight = 0
    private(set) var statusMessage = "请选择要滚动的区域"
    private(set) var mode: ScrollCaptureMode = .manual
    private(set) var isPaused = false
    private(set) var isFinishing = false
    private(set) var isAwaitingStart = false
    private(set) var livePreviewImage: NSImage?

    private let engine = SCKStillCaptureBackend()
    private var captureTask: Task<Void, Never>?
    private var targetRect: CGRect?
    private var targetProcessID: pid_t?
    private var previousImage: CGImage?
    private var segments: [CGImage] = []
    /// 已捕获内容区间（首帧顶行为 0）：决定追加底部 / 插入顶部 / 回退不拼。
    private var tracker: ScrollRangeTracker?
    /// 上一次成功匹配的滚动方向：自动模式的先验（手动模式不带先验——
    /// 准周期内容上先验会把"真实位移+周期"的错误解锁进记忆并自我强化）。
    private var lastScrollDirection: ScrollDirection?
    /// 长图头部/尾部最近若干灰度行的采样缓存：重复条带闸门的比对基准。
    private var stitchHeadRows: [[UInt8]] = []
    private var stitchTailRows: [[UInt8]] = []

    // MARK: - 移植自 capcap 的配准前置状态（MIT, github.com/realskyrin/capcap）
    //
    // 滚动条滑块和吸顶导航在两帧间不随内容移动，Vision 会把它们当作证据、
    // 报出一个"折中"的位移（通常远小于真实滚动量）。capcap 的做法是从
    // 首个有运动的帧对里把这两类区域检测出来，之后每帧喂给 Vision 前裁掉。
    private var scrollbarWidthPx = 0
    private var scrollbarDetected = false
    private var stickyHeaderPx = 0
    private var stickyHeaderDetectionDone = false
    private var stickyHeaderSamplesTaken = 0

    private var scaleFactor: CGFloat = 1
    private var displayID: CGDirectDisplayID?
    private var unchangedRounds = 0
    private var mismatchRounds = 0
    private var hasObservedGrowth = false
    /// Snapboard 式到底验证：首次判到底先补一次更长的滚动再确认。
    private var endVerificationAttempted = false
    private var originalCursorLocation: CGPoint?
    private var cursorHiddenOnDisplay: CGDirectDisplayID?
    private var lastCaptureFailureDescription: String?
    private var lastSampledScrollRows: Int?
    #if DEBUG
    private var auditOutputURL: URL?
    #endif
    /// 动态网页的图片懒加载通常会持续 1–3 秒；这段时间只原地重抓，不继续滚。
    private let maximumAutomaticMismatchRounds = 12
    private let automaticScrollStep: Int32 = 140
    /// capcap 同款帧数预算。
    private let maximumFrames = 100

    private enum FrameCaptureResult {
        case appended
        case prepended
        case unchanged
        case rolledBack
        case duplicateRejected
        case mismatch
        case limitReached
        case failed
    }

    private init() {}

    func start(
        on screen: NSScreen? = nil,
        presetRegion: CGRect? = nil,
        source: CaptureSource? = nil
    ) async {
        if isActive {
            // A previous transition may still be alive even if AppKit reordered its
            // non-activating panels behind the target application. A second click
            // must restore that session instead of silently swallowing the action.
            if let targetRect {
                ScrollCaptureStatusBarController.shared.show(
                    on: screen,
                    targetRect: targetRect
                )
                Self.logger.notice("Restored active scroll capture interface")
            }
            return
        }
        guard !isPreparing else {
            Self.logger.notice("Ignored start request while scroll capture is preparing")
            return
        }
        isPreparing = true
        defer { isPreparing = false }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .scrollCapture,
            on: screen
        ) else {
            Self.logger.error("Scroll capture screen permission was not granted")
            return
        }

        // 预设选区（从确认画面「滚动长图」转入）时跳过框选
        var pointsRect = presetRegion
        var captureSource = source
        if pointsRect == nil {
            statusMessage = "请框选需要滚动的内容"
            guard let selection = await RegionSelectionOverlay().selectRegion() else { return }
            pointsRect = selection.pointsRect
            captureSource = selection.source
        }
        guard let pointsRect else { return }

        targetRect = pointsRect
        targetProcessID = captureSource?.processID
        // 默认手动（ScrollSnap/飞书路线：兼容一切应用，不需要程序控制别人）；
        // 自动注入滚轮是需要辅助功能权限的增强模式，控制条上可切换。
        mode = .manual
        Self.logger.notice(
            "Locked target region width=\(Int(pointsRect.width), privacy: .public) height=\(Int(pointsRect.height), privacy: .public) mode=\(self.mode.rawValue, privacy: .public) accessibilityTrusted=\(UIElementDetector.isTrusted, privacy: .public) targetPID=\(self.targetProcessID ?? -1, privacy: .public)"
        )
        isActive = true
        isPaused = false
        isFinishing = false
        isAwaitingStart = true
        capturedFrameCount = 0
        stitchedHeight = 0
        livePreviewImage = nil
        statusMessage = "区域已锁定，正在准备长图"

        // Activate the captured application before creating the non-activating
        // status panels. Doing this in the opposite order lets macOS reorder the
        // freshly-created panels during app/Space activation, leaving an active
        // capture session with no visible outline or controls.
        activateTargetApplication()
        try? await Task.sleep(for: .milliseconds(100))
        guard isActive else { return }
        ScrollCaptureStatusBarController.shared.show(on: screen, targetRect: pointsRect)

        // 等待目标应用重新成为前台，也确保选区/确认蒙层已从 WindowServer 退场。
        try? await Task.sleep(for: .milliseconds(80))
        guard isActive else { return }

        do {
            let first = try await engine.capture(.region(pointsRect))
            // 首帧抓取期间用户仍可按 Esc；若已取消，不得把迟到的帧重新写回状态。
            guard isActive else { return }
            previousImage = first.image
            segments = [first.image]
            tracker = ScrollRangeTracker(frameHeight: first.image.height)
            let firstRows = Self.grayRowVectors(first.image)
            stitchHeadRows = Array(firstRows.prefix(600))
            stitchTailRows = Array(firstRows.suffix(600))
            scaleFactor = first.scaleFactor
            displayID = first.displayID
            capturedFrameCount = 1
            stitchedHeight = first.image.height
            updateLivePreview()
            statusMessage = mode == .automatic
                ? "点击“开始滚动”，或先调整到内容顶部"
                : manualReadyInstruction
            // The first ScreenCaptureKit request can itself cause a WindowServer
            // ordering pass. Reassert the panels once the session is ready so the
            // visible UI and the active controller cannot diverge.
            ScrollCaptureStatusBarController.shared.bringToFront()
            Self.logger.notice(
                "Captured first frame width=\(first.image.width, privacy: .public) height=\(first.image.height, privacy: .public)"
            )
        } catch {
            Self.logger.error(
                "First frame capture failed: \(String(describing: error), privacy: .public)"
            )
            isActive = false
            ScrollCaptureStatusBarController.shared.dismiss()
            restoreAutomaticCursor()
            reset()
            statusMessage = "滚动截图启动失败"
            showError("无法开始滚动截图：\(error.localizedDescription)")
        }
    }

    /// 飞书式两段确认：选区锁定后先保留边界和首帧预览，用户明确开始才滚动。
    /// 这样误选窗口或滚动容器时可以直接取消，不会一松手就把页面带走。
    func beginCapture() {
        guard isActive, isAwaitingStart, previousImage != nil, !isFinishing else { return }
        isAwaitingStart = false
        isPaused = false
        unchangedRounds = 0
        mismatchRounds = 0
        endVerificationAttempted = false
        hasObservedGrowth = false
        if mode == .automatic {
            prepareAutomaticCursor()
            statusMessage = "自动向下滚动中；可随时暂停或完成"
        } else {
            statusMessage = manualCaptureInstruction
        }
        Self.logger.notice("Capture polling began in mode=\(self.mode.rawValue, privacy: .public)")
        beginPolling()
    }

    func stop() async {
        guard isActive, !isFinishing else { return }
        guard !segments.isEmpty else {
            cancel()
            return
        }
        isFinishing = true
        isActive = false
        isAwaitingStart = false
        captureTask?.cancel()
        captureTask = nil
        restoreAutomaticCursor()

        // capcap 式收尾补帧：最后一次滚动状态不遗漏（无新增时为无害空转）
        if previousImage != nil {
            let settled = await captureSettledFrame()
            if let settled {
                _ = await captureNextFrame(stabilized: settled)
            }
        }

        statusMessage = "正在生成长图…"
        ScrollCaptureStatusBarController.shared.dismiss()

        guard let image = renderSegments() else {
            Self.logger.error("Failed to render \(self.segments.count, privacy: .public) scroll segments")
            isFinishing = false
            reset()
            showError("长图生成失败，请重试。")
            return
        }
        #if DEBUG
        if let auditOutputURL {
            let frameCount = capturedFrameCount
            let wroteImage = writeAuditImage(image, to: auditOutputURL)
            reset(keepStatus: true)
            statusMessage = wroteImage
                ? "验收长图已生成：\(frameCount) 段，\(image.height) 像素高"
                : "验收长图导出失败"
            return
        }
        #endif
        let frame = CapturedFrame(
            image: image,
            scaleFactor: scaleFactor,
            displayID: displayID
        )
        Self.logger.notice(
            "Rendered scroll capture frames=\(self.capturedFrameCount, privacy: .public) height=\(image.height, privacy: .public)"
        )
        reset(keepStatus: true)
        ScreenCapture.shared.playShutterSound()
        await CaptureOrchestrator.shared.processExternalFrame(frame)
    }

    func cancel() {
        captureTask?.cancel()
        captureTask = nil
        isActive = false
        isFinishing = false
        isAwaitingStart = false
        restoreAutomaticCursor()
        ScrollCaptureStatusBarController.shared.dismiss()
        reset()
    }

    func handleEscape() async {
        if isAwaitingStart {
            cancel()
        } else {
            await stop()
        }
    }

    func togglePause() {
        guard isActive, !isAwaitingStart, !isFinishing else { return }
        isPaused.toggle()
        statusMessage = isPaused
            ? "已暂停；画面不会继续滚动或拼接"
            : (mode == .automatic
                ? "自动向下滚动中；Esc 可提前完成"
                : manualCaptureInstruction)
    }

    func toggleMode() {
        guard isActive, !isFinishing else { return }
        if mode == .automatic {
            switchToManual(reason: "已切换为手动滚动；停顿不会自动结束")
            return
        }

        guard UIElementDetector.isTrusted, targetProcessID != nil else {
            UIElementDetector.requestAccess()
            statusMessage = targetProcessID == nil
                ? "没有识别到目标应用；当前继续手动捕获"
                : "自动滚动需要辅助功能权限；授权后再点一次"
            Self.logger.notice(
                "Automatic mode unavailable accessibilityTrusted=\(UIElementDetector.isTrusted, privacy: .public) hasTargetProcess=\(self.targetProcessID != nil, privacy: .public)"
            )
            return
        }

        mode = .automatic
        isPaused = false
        unchangedRounds = 0
        mismatchRounds = 0
        endVerificationAttempted = false
        hasObservedGrowth = false
        activateTargetApplication()
        if isAwaitingStart {
            statusMessage = "已切换自动滚动；点击“开始滚动”"
        } else {
            prepareAutomaticCursor()
            statusMessage = "自动向下滚动中；可随时暂停或完成"
        }
    }

    private func beginPolling() {
        unchangedRounds = 0
        mismatchRounds = 0
        endVerificationAttempted = false
        hasObservedGrowth = false
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            // 匹配失败通常发生在网页仍在惯性滚动、动画或懒加载时。失败后必须
            // 原地重抓，不能继续发送滚轮事件，否则位移会叠加到彻底失去重叠。
            var retryWithoutScrolling = false
            while !Task.isCancelled {
                guard !Task.isCancelled, let self, self.isActive else { break }

                if self.isPaused {
                    try? await Task.sleep(for: .milliseconds(180))
                    continue
                }

                let result: FrameCaptureResult
                if self.mode == .automatic {
                    if retryWithoutScrolling {
                        try? await Task.sleep(for: .milliseconds(280))
                    } else {
                        self.postAutomaticScroll()
                        try? await Task.sleep(for: .milliseconds(120))
                    }
                    // capcap 式稳定门：连续两次抓帧字节签名完全相同才算停稳
                    // （平滑滚动/懒加载期间只观察不拼接）。
                    let stabilized = await self.captureSettledFrame()
                    guard !Task.isCancelled, self.isActive else { break }
                    result = await self.captureNextFrame(stabilized: stabilized)
                } else {
                    try? await Task.sleep(for: .milliseconds(260))
                    guard !Task.isCancelled, self.isActive else { break }
                    result = await self.captureNextFrame()
                }

                switch result {
                case .appended, .prepended:
                    retryWithoutScrolling = false
                    self.hasObservedGrowth = true
                    self.unchangedRounds = 0
                    self.mismatchRounds = 0
                    self.endVerificationAttempted = false

                case .unchanged:
                    retryWithoutScrolling = false
                    self.mismatchRounds = 0
                    guard self.mode == .automatic else { continue }
                    self.unchangedRounds += 1
                    if self.hasObservedGrowth, self.unchangedRounds >= 5 {
                        if !self.endVerificationAttempted {
                            // Snapboard 式到底验证：先补一次更长的滚动再确认，
                            // 避免网页加载慢被误判到底而提前收工。
                            self.endVerificationAttempted = true
                            Self.logger.notice("End-of-page verification scroll")
                            self.postAutomaticScroll(multiplier: 2)
                            self.statusMessage = "正在确认是否已到底部…"
                        } else {
                            await self.stop()
                            return
                        }
                    }
                    if !self.hasObservedGrowth, self.unchangedRounds >= 5 {
                        self.switchToManual(
                            reason: "目标应用没有响应自动滚动，已切到手动模式"
                        )
                    }

                case .rolledBack:
                    // 回退到已捕获区间：不重复拼接，也不计入到底轮数。
                    retryWithoutScrolling = false
                    self.mismatchRounds = 0
                    self.statusMessage = "已回退；滚到新内容后会继续拼接"

                case .duplicateRejected:
                    // 闸门拦截（锚点未推进）：手动模式等用户回滚重新对齐；
                    // 自动模式停止注入滚轮、原地等画面回到锚点附近。
                    if self.mode == .automatic {
                        self.mismatchRounds += 1
                        retryWithoutScrolling = true
                        if self.mismatchRounds >= self.maximumAutomaticMismatchRounds {
                            self.switchToManual(
                                reason: "页面内容疑似重复，已切到手动；请稍回滚后慢一点"
                            )
                        } else {
                            self.statusMessage = "疑似重复内容已拦截，等待重新对齐…"
                        }
                    } else {
                        self.mismatchRounds = 0
                        self.statusMessage = "疑似重复内容已拦截；请稍微回滚后继续"
                    }

                case .mismatch:
                    self.mismatchRounds += 1
                    self.endVerificationAttempted = false
                    if self.mismatchRounds == 1 {
                        Self.logger.notice("Frame overlap mismatch")
                    }
                    if self.mode == .automatic,
                       self.mismatchRounds < self.maximumAutomaticMismatchRounds {
                        retryWithoutScrolling = true
                        self.statusMessage = "页面仍在变化，正在等待稳定后继续"
                    } else if self.mode == .automatic {
                        retryWithoutScrolling = false
                        self.switchToManual(
                            reason: "页面变化太快，已切到手动；请慢一点滚动"
                        )
                    } else if self.mode == .manual {
                        self.statusMessage = "没有找到重叠区域；请稍微回滚后慢一点"
                    }

                case .limitReached:
                    await self.stop()
                    return

                case .failed:
                    retryWithoutScrolling = self.mode == .automatic
                    if self.mode == .manual {
                        self.statusMessage = "暂时没有抓到画面；可继续滚动或点完成"
                    }
                }
            }
        }
    }

    /// capcap 式稳定帧：连续两次抓帧的**字节签名完全相同**才算页面停稳
    /// （12→80ms 几何退避，最多 20 轮 ≈ 1s）。比近似分数严格得多——
    /// 合成器还在画任何东西都瞒不过逐字节比对。超时返回最后一帧，
    /// 交给"整帧近乎相同"与范围校验兜底。
    private func captureSettledFrame() async -> CGImage? {
        guard let targetRect else { return nil }
        var previousSignature: Data?
        var lastFrame: CGImage?
        var waitMilliseconds = 12
        for _ in 0..<20 {
            guard !Task.isCancelled else { return lastFrame }
            guard let frame = try? await engine.capture(.region(targetRect)).image else {
                try? await Task.sleep(for: .milliseconds(30))
                continue
            }
            guard let signature = Self.pixelSignature(frame) else {
                lastFrame = frame
                try? await Task.sleep(for: .milliseconds(waitMilliseconds))
                waitMilliseconds = min(waitMilliseconds * 3 / 2, 80)
                continue
            }
            if let previousSignature, previousSignature == signature {
                return frame
            }
            previousSignature = signature
            lastFrame = frame
            try? await Task.sleep(for: .milliseconds(waitMilliseconds))
            waitMilliseconds = min(waitMilliseconds * 3 / 2, 80)
        }
        return lastFrame
    }

    /// CGImage 原始像素字节——确定性的逐帧签名。
    private static func pixelSignature(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    /// capcap 式"整帧近乎相同"：采样网格均差 < 3 → 两帧没有实质变化。
    private static func framesNearlyIdentical(_ lhs: GrayImage, _ rhs: GrayImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.width > 0, lhs.height > 0 else { return false }
        let columnCount = min(32, max(16, lhs.width / 6))
        let rowCount = min(32, max(16, lhs.height / 6))
        var total = 0
        var comparisons = 0
        for rowSample in 0..<rowCount {
            let y = min(lhs.height - 1, lhs.height * (rowSample * 2 + 1) / (rowCount * 2))
            for columnSample in 0..<columnCount {
                let x = min(lhs.width - 1, lhs.width * (columnSample * 2 + 1) / (columnCount * 2))
                total += abs(
                    Int(lhs.pixels[y * lhs.width + x]) - Int(rhs.pixels[y * lhs.width + x])
                )
                comparisons += 1
            }
        }
        guard comparisons > 0 else { return false }
        return Double(total) / Double(comparisons) < 3
    }

    /// 右缘 `edgeWidth` 像素、1:1 灰度条带（滚动条检测需要列级分辨率，
    /// 192 宽的缩略图不够）。
    private static func grayEdgeStrip(image: CGImage, edgeWidth: Int) -> GrayImage? {
        let width = min(edgeWidth, image.width)
        let height = image.height
        guard width > 4, height > 4 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(
                image,
                in: CGRect(x: CGFloat(image.width - width), y: 0, width: CGFloat(width), height: CGFloat(height))
            )
            return true
        }
        return created ? GrayImage(width: width, height: height, pixels: pixels) : nil
    }

    /// 条带的灰度行采样向量（每行 24 列），供重复条带闸门比对。
    private static func grayRowVectors(_ image: CGImage) -> [[UInt8]] {
        guard let gray = grayscale(image) else { return [] }
        let sampleCount = 24
        var vectors: [[UInt8]] = []
        vectors.reserveCapacity(gray.height)
        for y in 0..<gray.height {
            var row: [UInt8] = []
            row.reserveCapacity(sampleCount)
            for sample in 0..<sampleCount {
                let x = min(gray.width - 1, sample * gray.width / sampleCount)
                row.append(gray.pixels[y * gray.width + x])
            }
            vectors.append(row)
        }
        return vectors
    }

    private func captureNextFrame(stabilized: CGImage? = nil) async -> FrameCaptureResult {
        guard let targetRect, let previousImage, var tracker else { return .failed }
        guard capturedFrameCount < maximumFrames else {
            statusMessage = "已达到 \(maximumFrames) 帧上限，正在生成当前内容"
            return .limitReached
        }
        do {
            let nextImage: CGImage
            if let stabilized {
                nextImage = stabilized
            } else {
                nextImage = try await engine.capture(.region(targetRect)).image
            }
            guard nextImage.width == previousImage.width,
                  nextImage.height == previousImage.height else {
                statusMessage = "画面尺寸发生变化，请保持窗口大小不变"
                return .mismatch
            }
            guard let previousGray = Self.grayscale(previousImage),
                  let currentGray = Self.grayscale(nextImage) else { return .failed }

            // ① capcap：整帧近乎相同（采样网格均差 < 3）→ 画面未动
            if Self.framesNearlyIdentical(previousGray, currentGray) {
                return .unchanged
            }

            // ② 位移测量：capcap 式 Vision 配准为主（裁掉检测出的滚动条列与
            // 吸顶行，吃几乎整帧的证据）；配准不可用时灰度五分区投票兜底。
            let displacement: Int
            if let signedRows = visionNewContentRows(
                previous: previousImage,
                current: nextImage
            ) {
                // capcap 范围校验：新内容不足一行下限（≥8px 或帧高 0.5%）视为未动
                let minimumNewRows = max(8, nextImage.height / 200)
                guard abs(signedRows) >= minimumNewRows,
                      abs(signedRows) <= Int(CGFloat(nextImage.height) * 0.95) else {
                    return .unchanged
                }
                displacement = signedRows
            } else if let resolved = grayscaleFallbackDisplacement(
                previousGray: previousGray,
                currentGray: currentGray,
                fullHeight: nextImage.height
            ) {
                displacement = resolved
            } else {
                return .mismatch
            }

            // ③ 区间跟踪 + 重复条带闸门（Rune 自有：双向拼接、回退不重、
            // 准周期内容兜底）
            let plan = tracker.advance(byRows: displacement)
            switch plan {
            case .unchanged:
                return .unchanged

            case .rollback:
                self.tracker = tracker
                self.previousImage = nextImage
                return .rolledBack

            case .lostOverlap:
                return .mismatch

            case .appendBottom(let rows, let frameRows),
                 .prependTop(let rows, let frameRows):
                guard stitchedHeight + rows <= 100_000 else {
                    statusMessage = "长图已达到 100000 像素，正在生成当前内容"
                    self.tracker = tracker
                    return .limitReached
                }
                let isPrepend = {
                    if case .prependTop = plan { return true }
                    return false
                }()
                guard let crop = nextImage.cropping(to: CGRect(
                    x: 0,
                    y: frameRows.lowerBound,
                    width: nextImage.width,
                    height: rows
                )) else { return .failed }

                let newRows = Self.grayRowVectors(crop)
                let insertion: ScrollDuplicateGuard.Insertion = isPrepend ? .prepend : .append
                let boundary = isPrepend ? stitchHeadRows : stitchTailRows
                if ScrollDuplicateGuard.isDuplicate(
                    newRows: newRows,
                    boundaryRows: boundary,
                    insertion: insertion
                ) {
                    Self.logger.notice(
                        "Duplicate strip rejected rows=\(rows, privacy: .public) prepend=\(isPrepend, privacy: .public)"
                    )
                    return .duplicateRejected
                }

                self.tracker = tracker
                if isPrepend {
                    segments.insert(crop, at: 0)
                    stitchHeadRows.insert(contentsOf: newRows, at: 0)
                    if stitchHeadRows.count > 600 {
                        stitchHeadRows.removeLast(stitchHeadRows.count - 600)
                    }
                } else {
                    segments.append(crop)
                    stitchTailRows.append(contentsOf: newRows)
                    if stitchTailRows.count > 600 {
                        stitchTailRows.removeFirst(stitchTailRows.count - 600)
                    }
                }
                self.previousImage = nextImage
                lastCaptureFailureDescription = nil
                capturedFrameCount += 1
                stitchedHeight += rows
                updateLivePreview()
                statusMessage = (mode == .automatic ? "自动滚动" : "手动滚动")
                    + "：已拼接 \(capturedFrameCount) 段"
                Self.logger.debug(
                    "Stitched \(isPrepend ? "top" : "bottom", privacy: .public) rows=\(rows, privacy: .public) frames=\(self.capturedFrameCount, privacy: .public)"
                )
                return isPrepend ? .prepended : .appended
            }
        } catch {
            let description = String(describing: error)
            if description != lastCaptureFailureDescription {
                Self.logger.error("Frame capture failed: \(description, privacy: .public)")
                lastCaptureFailureDescription = description
            }
            return .failed
        }
    }

    // MARK: - 位移测量（配准部分移植自 capcap，MIT）

    /// Vision 配准测两帧间的有符号新内容行数（正 = 向下滚动露出底部新内容，
    /// 负 = 向上滚动露出顶部新内容，0 = 未动，nil = 配准不可用）。
    ///
    /// 与旧实现的区别（capcap 的关键改进）：喂给 Vision 的是**几乎整帧**
    /// 的证据，只裁掉"检测出来"的右侧滚动条列与顶部吸顶行——固定 UI 不再
    /// 把配准结果拉向折中值；两帧裁同一区域，ty 仍落在原帧坐标系。
    private func visionNewContentRows(previous: CGImage, current: CGImage) -> Int? {
        let width = min(previous.width, current.width)
        let height = min(previous.height, current.height)
        guard width >= 80, height >= 80 else { return nil }

        // 一次性滚动条检测（首个有运动的帧对）
        if !scrollbarDetected {
            detectScrollbar(previous: previous, current: current)
        }

        let cropWidth = max(0, width - scrollbarWidthPx)
        let cropY = stickyHeaderDetectionDone ? min(stickyHeaderPx, height / 5) : 0
        let cropHeight = height - cropY
        var visionPrevious = previous
        var visionCurrent = current
        if cropWidth >= 50, cropHeight >= 50, scrollbarWidthPx > 0 || cropY > 0 {
            let cropRect = CGRect(x: 0, y: cropY, width: cropWidth, height: cropHeight)
            visionPrevious = previous.cropping(to: cropRect) ?? previous
            visionCurrent = current.cropping(to: cropRect) ?? current
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: visionPrevious)
        let handler = VNImageRequestHandler(cgImage: visionCurrent, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first
                  as? VNImageTranslationAlignmentObservation else {
            return nil
        }

        let translation = observation.alignmentTransform.ty
        guard translation.isFinite else { return nil }
        let rows = Int(translation.rounded())

        // 首次看到真实位移 → 学习吸顶行边界
        if abs(rows) > 5, !stickyHeaderDetectionDone {
            detectStickyHeader(previous: previous, current: current)
        }
        return rows
    }

    /// capcap 式滚动条检测：从最右列向左扫，找出两帧间持续变化、且变化区
    /// 之外归于安静的列带 = 滚动条滑块。要求"动→静"边界成立才采信，避免
    /// 把右侧恰好是动画的内容当成滚动条。
    private func detectScrollbar(previous: CGImage, current: CGImage) {
        defer { scrollbarDetected = true }
        let edgeWidth = 64
        guard let previousStrip = Self.grayEdgeStrip(image: previous, edgeWidth: edgeWidth),
              let currentStrip = Self.grayEdgeStrip(image: current, edgeWidth: edgeWidth),
              previousStrip.width == currentStrip.width,
              previousStrip.height == currentStrip.height else { return }
        let width = previousStrip.width
        let height = previousStrip.height
        guard width > 20, height > 40 else { return }

        let maxScan = min(50, width / 2)
        let sampleStart = height / 5
        let sampleEnd = (height * 4) / 5
        let sampleStep = max(1, (sampleEnd - sampleStart) / 30)

        var detectedWidth = 0
        var sawQuietAfterMoving = false
        for offset in 0..<maxScan {
            let column = width - 1 - offset
            var totalDiff = 0
            var samples = 0
            var row = sampleStart
            while row < sampleEnd {
                totalDiff += abs(
                    Int(previousStrip.pixels[row * width + column])
                        - Int(currentStrip.pixels[row * width + column])
                )
                samples += 1
                row += sampleStep
            }
            guard samples > 0 else { continue }
            let average = totalDiff / samples
            if average > 4 {
                detectedWidth = offset + 1
            } else if detectedWidth > 0 {
                sawQuietAfterMoving = true
                break
            }
        }
        if sawQuietAfterMoving, detectedWidth >= 3, detectedWidth <= 40 {
            scrollbarWidthPx = detectedWidth + 4
        }
    }

    /// capcap 式吸顶检测：自上而下找第一行真正变化的内容，其上完全相同的
    /// 行数 = 吸顶区域。两次采样一致才锁定；<10 行或 >60% 帧高都不采信。
    private func detectStickyHeader(previous: CGImage, current: CGImage) {
        guard let previousGray = Self.grayscale(previous),
              let currentGray = Self.grayscale(current),
              previousGray.height == currentGray.height,
              previousGray.height > 40 else {
            stickyHeaderDetectionDone = true
            return
        }
        let grayHeight = previousGray.height
        let grayScale = CGFloat(previous.height) / CGFloat(grayHeight)
        let columnStart = previousGray.width / 10
        let columnEnd = (previousGray.width * 9) / 10
        let columnStep = max(1, (columnEnd - columnStart) / 20)

        var firstMovingRow = -1
        for row in 0..<grayHeight {
            var totalDiff = 0
            var samples = 0
            var column = columnStart
            while column <= columnEnd {
                totalDiff += abs(
                    Int(previousGray.pixels[row * previousGray.width + column])
                        - Int(currentGray.pixels[row * previousGray.width + column])
                )
                samples += 1
                column += columnStep
            }
            guard samples > 0 else { continue }
            if totalDiff / samples > 5 {
                firstMovingRow = row
                break
            }
        }

        guard firstMovingRow >= 0 else {
            // 整帧都没动：还轮不到做判断，等下一个有运动的帧对
            return
        }

        let frozenRows = Int(CGFloat(firstMovingRow) * grayScale)
        let maxPlausibleHeader = (previous.height * 6) / 10
        stickyHeaderSamplesTaken += 1

        if frozenRows < 10 {
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
        } else if frozenRows > maxPlausibleHeader {
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
        } else if stickyHeaderSamplesTaken == 1 {
            stickyHeaderPx = frozenRows
        } else if abs(frozenRows - stickyHeaderPx) <= Int(grayScale * 5) {
            stickyHeaderPx = min(stickyHeaderPx, frozenRows)
            stickyHeaderDetectionDone = true
        } else {
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = true
        }
    }

    /// 灰度五分区投票兜底（Vision 不可用时）：Rune 自有实现。
    /// 手动模式无先验（平局取最小位移），自动模式带步长先验。
    private func grayscaleFallbackDisplacement(
        previousGray: GrayImage,
        currentGray: GrayImage,
        fullHeight: Int
    ) -> Int? {
        let preferredOffset: Int?
        let preferredDirection: ScrollDirection?
        if mode == .automatic {
            if let lastSampledScrollRows {
                preferredOffset = lastSampledScrollRows
            } else {
                preferredOffset = max(2, Int((
                    CGFloat(automaticScrollStep) / CGFloat(fullHeight)
                        * CGFloat(currentGray.height)
                ).rounded()))
            }
            preferredDirection = lastScrollDirection ?? .down
        } else {
            preferredOffset = nil
            preferredDirection = nil
        }

        guard let match = ScrollOverlapDetector.detectScroll(
            previous: previousGray.pixels,
            current: currentGray.pixels,
            width: previousGray.width,
            height: previousGray.height,
            preferredOffset: preferredOffset,
            preferredDirection: preferredDirection
        ) else { return nil }

        if match.offsetRows == 0 {
            lastSampledScrollRows = nil
            return 0
        }
        let fullRows = max(1, Int((
            CGFloat(match.offsetRows) / CGFloat(currentGray.height) * CGFloat(fullHeight)
        ).rounded()))
        lastSampledScrollRows = match.offsetRows
        lastScrollDirection = match.direction
        return match.direction == .down ? fullRows : -fullRows
    }

    private var targetRectCenter: CGPoint? {
        targetRect.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private var manualCaptureInstruction: String {
        UIElementDetector.isTrusted
            ? "手动模式：上下滚动均可；Esc 或“完成”收尾"
            : "手动模式：上下滚动均可；点“完成”收尾"
    }

    private var manualReadyInstruction: String {
        if !UIElementDetector.isTrusted {
            return "手动滚动模式；点击“开始滚动”，随后在选区内上下滚动"
        }
        return "点击“开始滚动”，随后在选区内上下滚动（可切自动）"
    }

    private func activateTargetApplication() {
        guard let targetProcessID,
              let application = NSRunningApplication(processIdentifier: targetProcessID) else { return }
        application.activate(options: [.activateAllWindows])
    }

    private func prepareAutomaticCursor() {
        guard originalCursorLocation == nil, let center = targetRectCenter else { return }
        originalCursorLocation = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(center)
        if let displayID, CGDisplayHideCursor(displayID) == .success {
            cursorHiddenOnDisplay = displayID
        }
    }

    private func restoreAutomaticCursor() {
        if let originalCursorLocation {
            CGWarpMouseCursorPosition(originalCursorLocation)
        }
        if let cursorHiddenOnDisplay {
            CGDisplayShowCursor(cursorHiddenOnDisplay)
        }
        originalCursorLocation = nil
        cursorHiddenOnDisplay = nil
    }

    private func postAutomaticScroll(multiplier: Int32 = 1) {
        guard let center = targetRectCenter else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -automaticScrollStep * multiplier,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = center
        // 滚轮事件不能用 postToPid：Chromium / Electron 的滚动区域不会处理
        // 这种进程定向事件，界面会显示“自动滚动中”但页面位置始终不变。
        // 目标应用已在开始和恢复时激活，光标也已锁到选区中心，因此从 HID
        // 事件流投递，和真实触控板/鼠标滚动的命中路径一致。
        event.post(tap: .cghidEventTap)
    }

    private func switchToManual(reason: String) {
        mode = .manual
        unchangedRounds = 0
        mismatchRounds = 0
        restoreAutomaticCursor()
        activateTargetApplication()
        statusMessage = reason
    }

    private struct GrayImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private static func grayscale(_ image: CGImage) -> GrayImage? {
        let width = min(192, image.width)
        let height = max(16, Int(CGFloat(image.height) * CGFloat(width) / CGFloat(image.width)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let created = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? GrayImage(width: width, height: height, pixels: pixels) : nil
    }

    private func renderSegments() -> CGImage? {
        guard let first = segments.first else { return nil }
        let totalHeight = segments.reduce(0) { $0 + $1.height }
        guard let context = CGContext(
            data: nil,
            width: first.width,
            height: totalHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // 注意：不翻 CTM。实测裸 CGContext 里 draw(image) 本来就是正立的，
        // 先翻再画会把长图上下颠倒（与跨屏拼接器同款 bug）。
        // segments[0]=第一帧(顶部)，在 y-up 画布里从顶部往下排：
        var yUp: CGFloat = CGFloat(totalHeight)
        for segment in segments {
            let h = CGFloat(segment.height)
            yUp -= h
            context.draw(segment, in: CGRect(x: 0, y: yUp, width: CGFloat(first.width), height: h))
        }
        return context.makeImage()
    }

    #if DEBUG
    /// 将真实滚动截图验收产生的完整拼接结果写到临时目录，便于人工检查原图。
    func writeAuditImage(to url: URL) -> Bool {
        guard let image = renderSegments() else { return false }
        return writeAuditImage(image, to: url)
    }

    func configureAuditImageOutput(to url: URL?) {
        auditOutputURL = url
    }

    private func writeAuditImage(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
    #endif

    /// 实时预览只合成低分辨率缩略图，避免每次追加都重建数万像素高的成片。
    private func updateLivePreview() {
        guard let first = segments.first else {
            livePreviewImage = nil
            return
        }
        let totalHeight = segments.reduce(0) { $0 + $1.height }
        let maxWidth: CGFloat = 300
        let maxHeight: CGFloat = 860
        let scale = min(
            maxWidth / CGFloat(first.width),
            maxHeight / CGFloat(totalHeight),
            1
        )
        let width = max(1, Int((CGFloat(first.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(totalHeight) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        context.interpolationQuality = .medium
        // 逐段按整数行边界绘制：小数 y/高度会让每段在非整数像素上抗锯齿，
        // 段间留下半像素缝隙——表现为预览里的横线（成品走全分辨率整数
        // 绘制没有这个问题，因此只有预览可见）。
        var cumulativeRows = 0
        var previousTopRow = 0
        var segmentRows: [(top: Int, bottom: Int)] = []
        segmentRows.reserveCapacity(segments.count)
        for segment in segments {
            cumulativeRows += segment.height
            let topRow = min(height, Int((CGFloat(cumulativeRows) * scale).rounded()))
            segmentRows.append((previousTopRow, topRow))
            previousTopRow = topRow
        }
        for (index, segment) in segments.enumerated() {
            let rows = segmentRows[index]
            guard rows.bottom > rows.top else { continue }
            context.draw(
                segment,
                in: CGRect(
                    x: 0,
                    y: CGFloat(height - rows.bottom),
                    width: CGFloat(width),
                    height: CGFloat(rows.bottom - rows.top)
                )
            )
        }
        guard let image = context.makeImage() else { return }
        livePreviewImage = NSImage(
            cgImage: image,
            size: NSSize(width: CGFloat(width), height: CGFloat(height))
        )
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "滚动截图"
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func reset(keepStatus: Bool = false) {
        targetRect = nil
        targetProcessID = nil
        previousImage = nil
        segments.removeAll()
        tracker = nil
        lastScrollDirection = nil
        stitchHeadRows = []
        stitchTailRows = []
        scrollbarWidthPx = 0
        scrollbarDetected = false
        stickyHeaderPx = 0
        stickyHeaderDetectionDone = false
        stickyHeaderSamplesTaken = 0
        capturedFrameCount = 0
        stitchedHeight = 0
        unchangedRounds = 0
        mismatchRounds = 0
        endVerificationAttempted = false
        hasObservedGrowth = false
        lastCaptureFailureDescription = nil
        lastSampledScrollRows = nil
        #if DEBUG
        auditOutputURL = nil
        #endif
        mode = .manual
        isPaused = false
        isFinishing = false
        isAwaitingStart = false
        livePreviewImage = nil
        if !keepStatus { statusMessage = "请选择要滚动的区域" }
    }

    #if DEBUG
    func prepareAuditState(image: NSImage?) {
        isActive = true
        isAwaitingStart = false
        isPaused = false
        isFinishing = false
        mode = .automatic
        capturedFrameCount = 9
        stitchedHeight = 6_480
        statusMessage = "自动向下滚动中；可随时暂停或完成"
        livePreviewImage = image
    }
    #endif
}

@MainActor
final class ScrollCaptureStatusBarController {
    static let shared = ScrollCaptureStatusBarController()
    private var panels: [NSPanel] = []
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private init() {}

    func show(on screen: NSScreen? = nil, targetRect pointsRect: CGRect? = nil) {
        dismiss()
        guard let targetScreen = resolvedScreen(screen, pointsRect: pointsRect) else { return }
        let screenFrame = targetScreen.frame
        let fallback = CGRect(
            x: screenFrame.midX - min(screenFrame.width * 0.32, 520),
            y: screenFrame.midY - min(screenFrame.height * 0.32, 340),
            width: min(screenFrame.width * 0.64, 1_040),
            height: min(screenFrame.height * 0.64, 680)
        )
        let clippedTarget = pointsRect.map {
            Self.appKitRect(from: $0).intersection(screenFrame)
        }
        let targetRect: CGRect
        if let clippedTarget,
           !clippedTarget.isNull,
           clippedTarget.width > 1,
           clippedTarget.height > 1 {
            targetRect = clippedTarget
        } else {
            targetRect = fallback
        }

        showDimmingPanels(around: targetRect, in: screenFrame)
        showTargetOutline(targetRect)
        showLivePreview(anchoredTo: targetRect, in: screenFrame)
        showInstruction(anchoredTo: targetRect, in: screenFrame)
        showControls(anchoredTo: targetRect, in: screenFrame)
        installEscapeMonitors()
    }

    func dismiss() {
        removeEscapeMonitors()
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    func bringToFront() {
        for panel in panels {
            panel.orderFrontRegardless()
        }
    }

    private func resolvedScreen(_ preferred: NSScreen?, pointsRect: CGRect?) -> NSScreen? {
        if let pointsRect {
            let rect = Self.appKitRect(from: pointsRect)
            if let matching = NSScreen.screens.first(where: { !$0.frame.intersection(rect).isNull }) {
                return matching
            }
        }
        return preferred ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// RegionSelection 使用主屏左上原点的 CG 坐标；悬浮窗使用 AppKit 左下原点。
    private static func appKitRect(from pointsRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? pointsRect.maxY
        return CGRect(
            x: pointsRect.minX,
            y: primaryHeight - pointsRect.maxY,
            width: pointsRect.width,
            height: pointsRect.height
        )
    }

    private func showDimmingPanels(around target: CGRect, in screen: CGRect) {
        let rects = [
            CGRect(x: screen.minX, y: target.maxY, width: screen.width, height: screen.maxY - target.maxY),
            CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: target.minY - screen.minY),
            CGRect(x: screen.minX, y: target.minY, width: target.minX - screen.minX, height: target.height),
            CGRect(x: target.maxX, y: target.minY, width: screen.maxX - target.maxX, height: target.height),
        ]
        for rect in rects where rect.width > 0.5 && rect.height > 0.5 {
            let view = NSView(frame: CGRect(origin: .zero, size: rect.size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
            _ = makePanel(frame: rect, contentView: view, ignoresMouseEvents: true)
        }
    }

    private func showTargetOutline(_ target: CGRect) {
        let root = ScrollCaptureTargetOutlineView(size: target.size).runeTypography()
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: target.size)
        _ = makePanel(frame: target, contentView: host, ignoresMouseEvents: true)
    }

    private func showLivePreview(anchoredTo target: CGRect, in screen: CGRect) {
        let width: CGFloat = min(300, max(220, screen.width * 0.18))
        let height: CGFloat = min(860, screen.height - 80)
        let gap: CGFloat = 14
        let x: CGFloat
        if target.minX - screen.minX >= width + gap {
            x = target.minX - width - gap
        } else if screen.maxX - target.maxX >= width + gap {
            x = target.maxX + gap
        } else {
            x = screen.minX + 16
        }
        let y = min(
            max(target.minY, screen.minY + 16),
            screen.maxY - height - 16
        )
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let root = ScrollCaptureLivePreviewView(
            controller: .shared,
            maxSize: frame.size
        )
        .runeTypography()
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: frame.size)
        _ = makePanel(frame: frame, contentView: host, ignoresMouseEvents: true)
    }

    private func showInstruction(anchoredTo target: CGRect, in screen: CGRect) {
        let size = NSSize(width: min(560, max(300, target.width - 32)), height: 44)
        let frame = CGRect(
            x: min(max(target.midX - size.width / 2, screen.minX + 12), screen.maxX - size.width - 12),
            y: min(max(target.minY + 64, screen.minY + 12), screen.maxY - size.height - 12),
            width: size.width,
            height: size.height
        )
        let root = ScrollCaptureInstructionView(controller: .shared).runeTypography()
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        _ = makePanel(frame: frame, contentView: host, ignoresMouseEvents: true)
    }

    private func showControls(anchoredTo target: CGRect, in screen: CGRect) {
        let size = NSSize(width: 470, height: 54)
        let x = min(max(target.maxX - size.width, screen.minX + 12), screen.maxX - size.width - 12)
        let preferredY = target.minY - size.height - 12
        let y = preferredY >= screen.minY + 8 ? preferredY : target.minY + 12
        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        let root = ScrollCaptureControlBarView(controller: .shared)
            .environment(\.colorScheme, .dark)
            .runeTypography()
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        _ = makePanel(frame: frame, contentView: host, ignoresMouseEvents: false, shadow: true)
    }

    @discardableResult
    private func makePanel(
        frame: CGRect,
        contentView: NSView,
        ignoresMouseEvents: Bool,
        shadow: Bool = false
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = shadow
        panel.isReleasedWhenClosed = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouseEvents
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.contentView = contentView
        panel.orderFrontRegardless()
        panels.append(panel)
        return panel
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                await ScrollCaptureController.shared.handleEscape()
            }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                await ScrollCaptureController.shared.handleEscape()
            }
        }
    }

    private func removeEscapeMonitors() {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        localKeyMonitor = nil
        globalKeyMonitor = nil
    }
}

private struct ScrollCaptureTargetOutlineView: View {
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(RuneTheme.cyan, lineWidth: 1.5)

            Text("\(Int(size.width)) × \(Int(size.height))")
                .font(RuneFont.mono(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.94))
                )
                .padding(8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("滚动截图选区，宽 \(Int(size.width))，高 \(Int(size.height))")
    }
}

private struct ScrollCaptureLivePreviewView: View {
    @State var controller: ScrollCaptureController
    let maxSize: CGSize

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Spacer(minLength: 0)

            if let image = controller.livePreviewImage {
                let previewSize = fittedSize(for: image)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: previewSize.width, height: previewSize.height)
                    .background(Color.white)
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.white.opacity(0.78), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.24), radius: 6, y: 3)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在准备首帧")
                        .font(RuneFont.swiftUI(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 180, height: 100)
                .runeGlassSurface(cornerRadius: 12, elevation: .floating)
            }

            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack")
                Text("实时拼接")
                Spacer(minLength: 8)
                Text("\(controller.capturedFrameCount) 段")
                Text(heightText)
            }
            .font(RuneFont.mono(size: 9.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                Capsule().fill(Color.black.opacity(0.76))
            )
        }
        .frame(width: maxSize.width, height: maxSize.height, alignment: .bottomTrailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("滚动截图实时预览，已拼接 \(controller.capturedFrameCount) 段，\(heightText)")
    }

    private var heightText: String {
        guard controller.stitchedHeight > 0 else { return "准备中" }
        if controller.stitchedHeight >= 10_000 {
            return String(format: "%.1f 万 px", Double(controller.stitchedHeight) / 10_000)
        }
        return "\(controller.stitchedHeight) px"
    }

    private func fittedSize(for image: NSImage) -> CGSize {
        let source = image.size
        guard source.width > 0, source.height > 0 else { return .zero }
        let availableHeight = max(maxSize.height - 34, 1)
        let scale = min(maxSize.width / source.width, availableHeight / source.height, 1)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

private struct ScrollCaptureInstructionView: View {
    @State var controller: ScrollCaptureController

    var body: some View {
        Text(controller.statusMessage)
            .font(RuneFont.swiftUI(size: 12, weight: .semibold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.black.opacity(0.82))
            )
            .accessibilityLabel(controller.statusMessage)
    }
}

private struct ScrollCaptureControlBarView: View {
    @State var controller: ScrollCaptureController

    var body: some View {
        HStack(spacing: 8) {
            Button {
                controller.toggleMode()
            } label: {
                Label(controller.mode == .automatic ? "自动滚动" : "手动滚动", systemImage: controller.mode.systemImage)
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .foregroundStyle(controller.mode == .automatic ? RuneTheme.cyan : RuneTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        Capsule().fill(Color.white.opacity(0.07))
                    )
            }
            .buttonStyle(.plain)
            .help(controller.mode == .automatic ? "切换为手动滚动" : "切换为自动滚动")

            Spacer(minLength: 8)

            if !controller.isAwaitingStart {
                Button {
                    controller.togglePause()
                } label: {
                    Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                        .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .disabled(controller.capturedFrameCount == 0 || controller.isFinishing)
                .help(controller.isPaused ? "继续滚动截图" : "暂停滚动截图")
                .accessibilityLabel(controller.isPaused ? "继续滚动截图" : "暂停滚动截图")
            }

            Button {
                controller.cancel()
            } label: {
                Image(systemName: "xmark")
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                    .foregroundStyle(RuneTheme.signal)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .help("取消滚动截图")
            .accessibilityLabel("取消滚动截图")

            Button {
                if controller.isAwaitingStart {
                    controller.beginCapture()
                } else {
                    Task { await controller.stop() }
                }
            } label: {
                if controller.isAwaitingStart {
                    RuneTheme.primaryButtonLabel("开始滚动")
                } else {
                    Image(systemName: "checkmark")
                        .font(RuneFont.swiftUI(size: 12, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.82))
                        .frame(width: 34, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(RuneTheme.cyan)
                        )
                }
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .disabled(controller.capturedFrameCount == 0 || controller.isFinishing)
            .help(controller.isAwaitingStart ? "开始捕获滚动内容" : "完成并生成长图")
            .accessibilityLabel(controller.isAwaitingStart ? "开始滚动截图" : "完成滚动截图")
        }
        .padding(.horizontal, 10)
        .frame(width: 470, height: 52)
        .runeGlassSurface(cornerRadius: 12, elevation: .floating)
        .accessibilityElement(children: .contain)
    }
}
