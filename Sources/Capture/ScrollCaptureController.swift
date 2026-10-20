import AppKit
import CaptureKit
import CaptureKitSCK
import ImageIO
import OSLog
import SwiftUI
@preconcurrency import Vision

// 滚动配准核心（滚动条列/吸顶行检测、全帧 Vision 配准、
// 逐字节稳定帧、最少新内容行数校验、帧数预算、收尾补帧）移植自 capcap：
// https://github.com/realskyrin/capcap （MIT License, Copyright 2026 realskyrin）。
// 完整许可文本见随源码与安装包提供的 THIRD_PARTY_NOTICES.md。
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
    /// 首次确认滚动时锁定的固定栏，只在成片顶部/底部各保留一次。
    private var fixedBandsLocked = false
    private var fixedTopPx = 0
    private var fixedBottomPx = 0
    private var fixedHeaderImage: CGImage?
    private var fixedFooterImage: CGImage?
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
    /// 自动滚轮从上一张已接受的帧起总共发出多少逻辑像素；等待/重试时
    /// 不清零，避免把多次滚动误当作单次步长去匹配周期性卡片。
    private var automaticCommandedPointsSinceAnchor: Int32 = 0
    private var lastUnchangedWasExact = false
    private var lastMismatchHadStationaryBody = false
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
            guard let selection = await RegionSelectionOverlay().selectRegion(initialMode: .scroll) else { return }
            // 模式条被改成了别的项：交给编排器按新模式走（飞书同款——
            // 框选途中改主意不用退出重来）。
            if selection.mode != .scroll {
                await CaptureOrchestrator.shared.route(mode: selection.mode, selection: selection)
                return
            }
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
            fixedBandsLocked = false
            fixedTopPx = 0
            fixedBottomPx = 0
            fixedHeaderImage = nil
            fixedFooterImage = nil
            segments = [first.image]
            tracker = ScrollRangeTracker(frameHeight: first.image.height)
            // 头尾缓存必须与后续追加时用同一套采样网格，否则同一段内容
            // 在头尾与新增段上是两套采样点，均差会带系统性偏移。
            let firstRows = Self.grayRowVectors(
                Self.grayscale(first.image, width: Self.fineGrayWidth) ?? GrayImage(width: 0, height: 0, pixels: [])
            )
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
    func beginCapture() async {
        guard isActive, isAwaitingStart, !isPreparing,
              let targetRect, previousImage != nil, !isFinishing else { return }
        isPreparing = true
        defer { isPreparing = false }
        statusMessage = "正在确认滚动起点…"
        // 用户可以在锁定选区后先滚到内容顶部；真正开始时必须重抓首帧，
        // 否则旧画面与新位置可能相隔数屏，之后永远找不到重叠。
        do {
            let first = try await engine.capture(.region(targetRect))
            guard isActive, isAwaitingStart, !isFinishing, !Task.isCancelled else { return }
            previousImage = first.image
            segments = [first.image]
            tracker = ScrollRangeTracker(frameHeight: first.image.height)
            let firstRows = Self.grayRowVectors(
                Self.grayscale(first.image, width: Self.fineGrayWidth) ?? GrayImage(width: 0, height: 0, pixels: [])
            )
            stitchHeadRows = Array(firstRows.prefix(600))
            stitchTailRows = Array(firstRows.suffix(600))
            fixedBandsLocked = false
            fixedTopPx = 0
            fixedBottomPx = 0
            fixedHeaderImage = nil
            fixedFooterImage = nil
            scrollbarWidthPx = 0
            scrollbarDetected = false
            stickyHeaderPx = 0
            stickyHeaderDetectionDone = false
            stickyHeaderSamplesTaken = 0
            lastSampledScrollRows = nil
            lastScrollDirection = nil
            scaleFactor = first.scaleFactor
            displayID = first.displayID
            capturedFrameCount = 1
            stitchedHeight = first.image.height
            updateLivePreview()
        } catch {
            Self.logger.error("Failed to refresh scroll starting frame: \(String(describing: error), privacy: .public)")
            statusMessage = "起始位置抓取失败；请再点一次“开始滚动”"
            return
        }
        isAwaitingStart = false
        isPaused = false
        unchangedRounds = 0
        mismatchRounds = 0
        endVerificationAttempted = false
        hasObservedGrowth = false
        automaticCommandedPointsSinceAnchor = 0
        lastUnchangedWasExact = false
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
                _ = await captureNextFrame(stabilized: settled, allowWhileFinishing: true)
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
        if let auditOutputURL, !Self.keepsAuditResultBarOpen {
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
        // 结果直出（飞书同款）：长图预览 + 编辑/下载/取消/保存到剪贴板，
        // 不再把用户丢回确认台。
        ScrollCaptureStatusBarController.shared.dismiss()
        await CaptureOrchestrator.shared.presentScrollCaptureResult(
            frame,
            on: NSScreen.main
        )
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
        lastSampledScrollRows = nil
        lastScrollDirection = .down
        automaticCommandedPointsSinceAnchor = 0
        lastUnchangedWasExact = false
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
            var uncertainStationaryRounds = 0
            var endVerificationStartedAt: Date?
            var endVerificationProbeCount = 0
            var wasPaused = false
            while !Task.isCancelled {
                guard !Task.isCancelled, let self, self.isActive else { break }

                if self.isPaused {
                    wasPaused = true
                    try? await Task.sleep(for: .milliseconds(180))
                    continue
                }
                if wasPaused {
                    // 暂停期间可能加载了新内容，墙钟时间不能算作
                    // 已经观察过的“到底确认”。恢复后先原地取证。
                    wasPaused = false
                    self.endVerificationAttempted = false
                    self.unchangedRounds = 0
                    endVerificationStartedAt = nil
                    endVerificationProbeCount = 0
                    retryWithoutScrolling = true
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
                    uncertainStationaryRounds = 0
                    self.automaticCommandedPointsSinceAnchor = 0
                    self.hasObservedGrowth = true
                    self.unchangedRounds = 0
                    self.mismatchRounds = 0
                    self.endVerificationAttempted = false
                    endVerificationStartedAt = nil
                    endVerificationProbeCount = 0

                case .unchanged:
                    self.mismatchRounds = 0
                    guard self.mode == .automatic else { continue }
                    guard self.lastUnchangedWasExact else {
                        // 动图、光标或懒加载会使画面接近静止但字节不同。
                        // 原地等有限次数；不能无限发滚轮，更不能当作到底。
                        uncertainStationaryRounds += 1
                        retryWithoutScrolling = true
                        self.unchangedRounds = 0
                        self.endVerificationAttempted = false
                        endVerificationStartedAt = nil
                        endVerificationProbeCount = 0
                        if uncertainStationaryRounds >= 8 {
                            self.switchToManual(
                                reason: "页面持续变化，无法确认到底；已切到手动，请检查后完成"
                            )
                        } else {
                            self.statusMessage = "画面还在变化，正在等待稳定…"
                        }
                        continue
                    }
                    uncertainStationaryRounds = 0
                    retryWithoutScrolling = false
                    // 完全相同的画面通常表示之前的滚轮命令没有推进锚点。
                    // 不能把这些疑似无效命令继续累加，否则稍后内容加载时
                    // 位移上限会膨胀到整屏，周期卡片又能造成跳页。
                    self.automaticCommandedPointsSinceAnchor = 0
                    self.unchangedRounds += 1
                    if self.hasObservedGrowth, self.unchangedRounds >= 5 {
                        if !self.endVerificationAttempted {
                            // Snapboard 式到底验证：先补一次更长的滚动再确认，
                            // 避免网页加载慢被误判到底而提前收工。
                            self.endVerificationAttempted = true
                            endVerificationStartedAt = Date()
                            endVerificationProbeCount = 0
                            Self.logger.notice("End-of-page verification scroll")
                            self.postAutomaticScroll(multiplier: 2)
                            // 验证滚轮已经发出；下一轮先观察它的结果，
                            // 不能再叠加普通滚轮后才抓帧。
                            retryWithoutScrolling = true
                            self.statusMessage = "正在确认是否已到底部…"
                        } else {
                            // 懒加载可能在当前视口下方追加内容，画面不会
                            // 自动跟着滚动。等待期间最多补四次小步探测，
                            // 每次先观察结果，绝不连发滚轮。
                            let elapsed = endVerificationStartedAt.map {
                                Date().timeIntervalSince($0)
                            } ?? 0
                            let nextProbeTime = Double(endVerificationProbeCount + 1) * 1.5
                            if endVerificationProbeCount < 4, elapsed >= nextProbeTime {
                                self.postAutomaticScroll()
                                endVerificationProbeCount += 1
                                retryWithoutScrolling = true
                                self.statusMessage = "正在检查页面下方是否有新内容…"
                                continue
                            }
                            if endVerificationProbeCount >= 4, elapsed >= 8.0 {
                                await self.stop()
                                return
                            }
                            retryWithoutScrolling = true
                            self.statusMessage = "正在等待页面完成加载…"
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
                    uncertainStationaryRounds = 0
                    self.automaticCommandedPointsSinceAnchor = 0
                    self.mismatchRounds = 0
                    self.unchangedRounds = 0
                    self.endVerificationAttempted = false
                    endVerificationStartedAt = nil
                    endVerificationProbeCount = 0
                    self.statusMessage = "已回退；滚到新内容后会继续拼接"

                case .duplicateRejected:
                    // 闸门拦截（锚点未推进）：手动模式等用户回滚重新对齐；
                    // 自动模式不再向前滚，以免锚点停在旧内容而页面一路滚到
                    // 底部，最后导出一张看似完整、实际漏掉后半段的图。
                    self.unchangedRounds = 0
                    uncertainStationaryRounds = 0
                    self.endVerificationAttempted = false
                    endVerificationStartedAt = nil
                    endVerificationProbeCount = 0
                    if self.mode == .automatic {
                        self.mismatchRounds += 1
                        retryWithoutScrolling = true
                        if self.mismatchRounds >= 3 {
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
                    uncertainStationaryRounds = 0
                    // 在“到底确认”期间，文档可能在视口下方追加内容：
                    // 底缘露出新卡片或滚动条改变，会使当前帧无法配准。
                    // 只有正文主体仍静止、变化局限在边缘时，才用剩余
                    // 的小步探测寻找新增段；正文真动了则不能再滚。
                    if self.mode == .automatic,
                       self.endVerificationAttempted,
                       self.lastMismatchHadStationaryBody,
                       let endVerificationStartedAt,
                       endVerificationProbeCount < 4 {
                        let elapsed = Date().timeIntervalSince(endVerificationStartedAt)
                        let nextProbeTime = Double(endVerificationProbeCount + 1) * 1.5
                        if elapsed >= nextProbeTime {
                            self.postAutomaticScroll()
                            endVerificationProbeCount += 1
                        }
                        retryWithoutScrolling = true
                        self.mismatchRounds = 0
                        self.statusMessage = "页面可能新增内容，正在分次向下确认…"
                        continue
                    }
                    self.mismatchRounds += 1
                    self.unchangedRounds = 0
                    self.endVerificationAttempted = false
                    endVerificationStartedAt = nil
                    endVerificationProbeCount = 0
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
                    uncertainStationaryRounds = 0
                    retryWithoutScrolling = self.mode == .automatic
                    self.unchangedRounds = 0
                    self.endVerificationAttempted = false
                    endVerificationStartedAt = nil
                    endVerificationProbeCount = 0
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
    /// 仍须通过两套位移证据和重叠区校验才能拼接。
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

    /// 同尺寸整帧的灰度行采样向量（每行 24 列），供重复条带闸门比对。
    /// 不能单独缩小裁下来的新条带：与首帧采用不同的缩放比例/采样起点后，
    /// 原本同一行也会算出不同亮度，导致重复内容漏拦。
    private static func grayRowVectors(_ image: CGImage) -> [[UInt8]] {
        guard let gray = grayscale(image) else { return [] }
        return grayRowVectors(gray)
    }

    private static func grayRowVectors(_ gray: GrayImage) -> [[UInt8]] {
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

    /// 固定栏只决定一次，并把首帧换成相同的内容视口；之后每帧都在这个
    /// 视口中测位移和裁新内容。固定栏自身留到最终绘图时各放一次。
    private func establishFixedBands(
        _ bands: ScrollFixedBands,
        firstImage: CGImage,
        grayHeight: Int
    ) -> Bool {
        guard grayHeight > 0 else { return false }
        let top = Int((Double(bands.topRows) / Double(grayHeight)
            * Double(firstImage.height)).rounded())
        let bottom = Int((Double(bands.bottomRows) / Double(grayHeight)
            * Double(firstImage.height)).rounded())
        guard top >= 0, bottom >= 0,
              top + bottom < firstImage.height * 2 / 5 else { return false }
        let contentHeight = firstImage.height - top - bottom
        guard contentHeight >= 80,
              let content = firstImage.cropping(to: CGRect(
                x: 0, y: top, width: firstImage.width, height: contentHeight
              )) else { return false }
        let header = top > 0
            ? firstImage.cropping(to: CGRect(x: 0, y: 0, width: firstImage.width, height: top))
            : nil
        let footer = bottom > 0
            ? firstImage.cropping(to: CGRect(
                x: 0, y: firstImage.height - bottom, width: firstImage.width, height: bottom
              ))
            : nil
        guard (top == 0 || header != nil), (bottom == 0 || footer != nil) else {
            return false
        }
        fixedHeaderImage = header
        fixedFooterImage = footer
        fixedTopPx = top
        fixedBottomPx = bottom
        fixedBandsLocked = true
        segments = [content]
        tracker = ScrollRangeTracker(frameHeight: contentHeight)
        let contentRows = Self.grayRowVectors(content)
        stitchHeadRows = Array(contentRows.prefix(600))
        stitchTailRows = Array(contentRows.suffix(600))

        // 配准裁切范围改变后，早期未确认帧学到的滚动条/吸顶状态不可复用。
        scrollbarWidthPx = 0
        scrollbarDetected = false
        stickyHeaderPx = 0
        stickyHeaderDetectionDone = false
        stickyHeaderSamplesTaken = 0
        Self.logger.notice(
            "Locked fixed bands top=\(top, privacy: .public) bottom=\(bottom, privacy: .public)"
        )
        updateLivePreview()
        return true
    }

    private func discardProvisionalFixedBands(firstImage: CGImage) {
        fixedBandsLocked = false
        fixedTopPx = 0
        fixedBottomPx = 0
        fixedHeaderImage = nil
        fixedFooterImage = nil
        segments = [firstImage]
        tracker = ScrollRangeTracker(frameHeight: firstImage.height)
        let rows = Self.grayRowVectors(firstImage)
        stitchHeadRows = Array(rows.prefix(600))
        stitchTailRows = Array(rows.suffix(600))
        scrollbarWidthPx = 0
        scrollbarDetected = false
        stickyHeaderPx = 0
        stickyHeaderDetectionDone = false
        stickyHeaderSamplesTaken = 0
        updateLivePreview()
    }

    private func contentImage(_ image: CGImage) -> CGImage? {
        guard fixedTopPx > 0 || fixedBottomPx > 0 else { return image }
        let height = image.height - fixedTopPx - fixedBottomPx
        guard height > 0 else { return nil }
        return image.cropping(to: CGRect(
            x: 0, y: fixedTopPx, width: image.width, height: height
        ))
    }

    private var renderedSegments: [CGImage] {
        var images: [CGImage] = []
        if let fixedHeaderImage { images.append(fixedHeaderImage) }
        images.append(contentsOf: segments)
        if let fixedFooterImage { images.append(fixedFooterImage) }
        return images
    }

    private func captureNextFrame(
        stabilized: CGImage? = nil,
        allowWhileFinishing: Bool = false
    ) async -> FrameCaptureResult {
        guard let targetRect, let previousImage, var tracker else { return .failed }
        lastMismatchHadStationaryBody = false
        var provisionalFixedBands = false
        var acceptedFixedBands = false
        defer {
            if provisionalFixedBands && !acceptedFixedBands {
                discardProvisionalFixedBands(firstImage: previousImage)
            }
        }
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
            // 手动轮询可能在抓帧的 await 期间遇到“完成/取消”。旧轮询
            // 不得与收尾补帧同时推进同一张图；只有 stop 自己的补帧例外。
            guard allowWhileFinishing
                ? isFinishing
                : (isActive && !isFinishing && !Task.isCancelled) else { return .failed }
            guard nextImage.width == previousImage.width,
                  nextImage.height == previousImage.height else {
                statusMessage = "画面尺寸发生变化，请保持窗口大小不变"
                return .mismatch
            }
            guard let previousFullGray = Self.grayscale(previousImage),
                  let currentFullGray = Self.grayscale(nextImage) else { return .failed }
            // 文档在视口下方增长时，正文主体没动；可能只有底缘
            // 露出新卡片的一小条，也可能只有右侧滚动条改变。
            // 仅这种失配才允许“到底确认”补滚。
            lastMismatchHadStationaryBody = Self.bodyIsStationaryIgnoringBorders(
                previous: previousFullGray,
                current: currentFullGray
            )
            if let previousSignature = Self.pixelSignature(previousImage),
               let currentSignature = Self.pixelSignature(nextImage) {
                lastUnchangedWasExact = previousSignature == currentSignature
            } else {
                lastUnchangedWasExact = false
            }

            // 只在第一段内容尚未拼入时确定固定栏。一旦改变视口高度，既有
            // 区间坐标就会失效，所以不能在截到一半后再重新裁切。
            if !fixedBandsLocked {
                let candidateBands = ScrollFixedBandDetector.detect(
                    previous: previousFullGray.pixels,
                    current: currentFullGray.pixels,
                    width: previousFullGray.width,
                    height: previousFullGray.height
                )
                // 两帧中的相同卡片标题与真正的固定顶栏可能像素完全同形；
                // 自动裁顶栏会永久丢掉聊天内容。向下滚动本就不会重复追加
                // 顶栏，故只处理证据较强、且真实长图已复现问题的底栏。
                let bands = ScrollFixedBands(topRows: 0, bottomRows: candidateBands.bottomRows)
                if bands.topRows > 0 || bands.bottomRows > 0 {
                    guard establishFixedBands(
                        bands,
                        firstImage: previousImage,
                        grayHeight: previousFullGray.height
                    ), let establishedTracker = self.tracker else { return .failed }
                    tracker = establishedTracker
                    provisionalFixedBands = true
                }
            }
            guard let previousContent = contentImage(previousImage),
                  let currentContent = contentImage(nextImage) else { return .failed }
            let previousGray: GrayImage
            let currentGray: GrayImage
            // 粗尺度（192 宽）覆盖面大、速度快；细尺度（480 宽）量化误差小。
            // 两级配合用：粗解找不到重叠时由细尺度整体重找，粗解有解时由细尺度
            // 窄窗精修。位移一律以**细尺度行**表达，下游换算统一用细尺度行高。
            guard let previousCoarseGray = Self.grayscale(
                    previousContent, width: Self.coarseGrayWidth
                ),
                  let currentCoarseGray = Self.grayscale(
                    currentContent, width: Self.coarseGrayWidth
                ),
                  let previousFineGray = Self.grayscale(
                    previousContent, width: Self.fineGrayWidth
                ),
                  let currentFineGray = Self.grayscale(
                    currentContent, width: Self.fineGrayWidth
                ) else {
                return .failed
            }
            previousGray = previousFineGray
            currentGray = currentFineGray

            // 两套方法独立测量位移。重复卡片能让图像配准锁到另一个周期，
            // 所以即便它给出了数字，也要用灰度分区投票及重叠区得分核对。
            let visionRows = visionNewContentRows(
                previous: previousContent,
                current: currentContent
            )
            let commandedPoints = automaticCommandedPointsSinceAnchor > 0
                ? automaticCommandedPointsSinceAnchor : automaticScrollStep
            let commandedGrayRows = max(2, Int((
                CGFloat(commandedPoints) * scaleFactor
                    / CGFloat(currentContent.height)
                    * CGFloat(currentCoarseGray.height)
            ).rounded()))
            let preferredOffset = mode == .automatic
                ? (automaticCommandedPointsSinceAnchor > 0
                    ? commandedGrayRows : lastSampledScrollRows ?? commandedGrayRows)
                : nil
            // 自动滚动有明确的滚轮距离。周期卡片可能让配准算法误选
            // 远处的另一张相似卡片；这种“大跳跃”必须停下，而非拼接。
            let maximumAutomaticGrayRows = mode == .automatic
                ? min(currentGray.height - 1, max(3, Int((Double(commandedGrayRows) * 1.8).rounded(.up))))
                : nil
            let grayMatch = ScrollOverlapDetector.detectScrollTwoScale(
                coarsePrevious: ScrollGrayFrame(
                    pixels: previousCoarseGray.pixels,
                    width: previousCoarseGray.width,
                    height: previousCoarseGray.height
                ),
                coarseCurrent: ScrollGrayFrame(
                    pixels: currentCoarseGray.pixels,
                    width: currentCoarseGray.width,
                    height: currentCoarseGray.height
                ),
                finePrevious: ScrollGrayFrame(
                    pixels: previousFineGray.pixels,
                    width: previousFineGray.width,
                    height: previousFineGray.height
                ),
                fineCurrent: ScrollGrayFrame(
                    pixels: currentFineGray.pixels,
                    width: currentFineGray.width,
                    height: currentFineGray.height
                ),
                preferredOffset: preferredOffset,
                preferredDirection: mode == .automatic ? (lastScrollDirection ?? .down) : nil,
                maximumOffset: maximumAutomaticGrayRows
            )
            let visionScore: Double? = visionRows.flatMap { rows in
                let grayRows = max(1, Int((
                    Double(abs(rows)) / Double(currentContent.height)
                        * Double(currentGray.height)
                ).rounded()))
                return ScrollOverlapDetector.scoreOffset(
                    previous: previousGray.pixels,
                    current: currentGray.pixels,
                    width: previousGray.width,
                    height: previousGray.height,
                    offsetRows: grayRows,
                    direction: rows >= 0 ? .down : .up
                )
            }
            var recoveredFromTail = false
            let resolvedDisplacement = ScrollDisplacementResolver.resolve(
                visionRows: visionRows,
                grayMatch: grayMatch,
                visionHypothesisScore: visionScore,
                grayHeight: currentGray.height,
                fullHeight: currentContent.height
            )
            var displacement: Int
            if let resolvedDisplacement {
                displacement = resolvedDisplacement
            } else if let recovered = recoverDisplacementFromStitchedTail(
                previousGray: previousGray,
                currentGray: currentGray,
                currentContent: currentContent
            ) {
                // 相邻帧证据冲突：先试长图尾部重锚（上一帧可能只是被
                // 动画/惯性弄脏），救得回来就不进入失配流程。
                Self.logger.notice(
                    "Recovered displacement from stitched tail rows=\(recovered, privacy: .public)"
                )
                if recovered == 0 {
                    // 画面其实没动，只是上一锚帧脏了：换上干净帧再走未变流程。
                    self.previousImage = nextImage
                    return .unchanged
                }
                recoveredFromTail = true
                displacement = recovered
            } else {
                Self.logger.notice(
                    "Conflicting scroll evidence vision=\(visionRows ?? 0, privacy: .public) gray=\(grayMatch?.offsetRows ?? -1, privacy: .public) score=\(visionScore ?? -1, privacy: .public)"
                )
                return .mismatch
            }
            // 尾部重锚得到的位移不经过“指令步长上限”：该上限防的是相邻帧
            // 配准在周期卡片上跳周期，而尾部锚定自带无歧义校验，直接信分数。
            if let maximumAutomaticGrayRows, !recoveredFromTail {
                // 上限是**粗尺度行**（两级检测的输入口径），换算回全分辨率
                // 必须用粗尺度行高；误用细尺度行高会把上限压掉一半，
                // 正常的滚动位移反而被判成"超出滚动距离"。
                let maximumFullRows = Int((
                    Double(maximumAutomaticGrayRows) / Double(currentCoarseGray.height)
                        * Double(currentContent.height)
                ).rounded(.up))
                guard abs(displacement) <= maximumFullRows else {
                    Self.logger.notice(
                        "Automatic scroll displacement exceeded commanded range rows=\(displacement, privacy: .public) max=\(maximumFullRows, privacy: .public)"
                    )
                    return .mismatch
                }
            }
            guard displacement != 0 else { return .unchanged }
            let minimumNewRows = max(8, currentContent.height / 200)
            guard abs(displacement) >= minimumNewRows else { return .unchanged }

            // 无论仲裁最终采用哪一种位移，实际重叠区都必须对得上。
            func overlapScoreFor(_ candidate: Int) -> Double? {
                let rows = max(1, Int((
                    Double(abs(candidate)) / Double(currentContent.height)
                        * Double(currentGray.height)
                ).rounded()))
                return ScrollOverlapDetector.scoreOffset(
                    previous: previousGray.pixels,
                    current: currentGray.pixels,
                    width: previousGray.width,
                    height: previousGray.height,
                    offsetRows: rows,
                    direction: candidate > 0 ? .down : .up
                )
            }
            if overlapScoreFor(displacement).map({ $0 > 18 }) ?? true {
                // 相邻帧重叠区对不上：上一帧被弄脏时这是主要症状，
                // 先试长图尾部重锚，再用同样的 18 分门槛复核。
                guard let recovered = recoverDisplacementFromStitchedTail(
                        previousGray: previousGray,
                        currentGray: currentGray,
                        currentContent: currentContent
                      ),
                      abs(recovered) >= minimumNewRows,
                      abs(recovered) < currentContent.height,
                      overlapScoreFor(recovered).map({ $0 <= 18 }) ?? false else {
                    return .mismatch
                }
                Self.logger.notice(
                    "Recovered displacement from stitched tail rows=\(recovered, privacy: .public)"
                )
                recoveredFromTail = true
                displacement = recovered
            }

            // ③ 区间跟踪 + 重复条带闸门（Rune 自有：双向拼接、回退不重、
            // 准周期内容兜底）
            let plan = tracker.advance(byRows: displacement)
            switch plan {
            case .unchanged:
                return .unchanged

            case .rollback:
                fixedBandsLocked = true
                acceptedFixedBands = true
                self.tracker = tracker
                self.previousImage = nextImage
                learnStationaryRegions(previous: previousContent, current: currentContent)
                rememberAcceptedScroll(
                    displacement,
                    grayHeight: currentCoarseGray.height,
                    fullHeight: currentContent.height
                )
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
                guard let crop = currentContent.cropping(to: CGRect(
                    x: 0,
                    y: frameRows.lowerBound,
                    width: currentContent.width,
                    height: rows
                )) else { return .failed }

                let fullFrameRows = Self.grayRowVectors(currentGray)
                let grayStart = max(0, min(currentGray.height, Int((
                    Double(frameRows.lowerBound) / Double(currentContent.height)
                        * Double(currentGray.height)
                ).rounded(.down))))
                let grayEnd = max(grayStart, min(currentGray.height, Int((
                    Double(frameRows.upperBound) / Double(currentContent.height)
                        * Double(currentGray.height)
                ).rounded(.up))))
                let newRows = Array(fullFrameRows[grayStart..<grayEnd])
                let insertion: ScrollDuplicateGuard.Insertion = isPrepend ? .prepend : .append
                let boundary = isPrepend ? stitchHeadRows : stitchTailRows
                let evidence = ScrollDuplicateGuard.measureRepetition(
                    newRows: newRows,
                    boundaryRows: boundary,
                    insertion: insertion
                )
                let mean: Double = evidence?.meanDifference ?? -1
                let verbatim: Double = evidence?.verbatimRowRatio ?? -1
                let shorter: Bool = evidence?.hasShorterMatch ?? false
                let shorterVerbatim: Double = evidence?.shorterMatchVerbatimRowRatio ?? -1
                Self.logger.debug(
                    "Strip repetition rows=\(rows, privacy: .public) prepend=\(isPrepend, privacy: .public) mean=\(mean, privacy: .public) verbatim=\(verbatim, privacy: .public) shorterMatch=\(shorter, privacy: .public) shorterVerbatim=\(shorterVerbatim, privacy: .public)"
                )
                if ScrollDuplicateGuard.isDuplicate(
                    newRows: newRows,
                    boundaryRows: boundary,
                    insertion: insertion
                ) {
                    Self.logger.notice(
                        "Duplicate strip rejected rows=\(rows, privacy: .public) prepend=\(isPrepend, privacy: .public) mean=\(mean, privacy: .public) verbatim=\(verbatim, privacy: .public) shorterMatch=\(shorter, privacy: .public) shorterVerbatim=\(shorterVerbatim, privacy: .public)"
                    )
                    return .duplicateRejected
                }

                fixedBandsLocked = true
                acceptedFixedBands = true
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
                learnStationaryRegions(previous: previousContent, current: currentContent)
                rememberAcceptedScroll(
                    displacement,
                    grayHeight: currentCoarseGray.height,
                    fullHeight: currentContent.height
                )
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

    private func rememberAcceptedScroll(_ rows: Int, grayHeight: Int, fullHeight: Int) {
        lastScrollDirection = rows > 0 ? .down : .up
        lastSampledScrollRows = max(1, Int((
            Double(abs(rows)) / Double(fullHeight) * Double(grayHeight)
        ).rounded()))
    }

    /// 只从真正通过重叠校验且进入区间跟踪的帧学习固定区域。若在首帧
    /// 尚未滚动时就锁定滚动条状态，之后的滚动条永远不会再被识别。
    private func learnStationaryRegions(previous: CGImage, current: CGImage) {
        if !scrollbarDetected {
            detectScrollbar(previous: previous, current: current)
        }
        if !stickyHeaderDetectionDone {
            detectStickyHeader(previous: previous, current: current)
        }
    }

    // MARK: - 失配自愈（长图尾部重锚，思想源自 ShareX 与成品比对的公开思路）

    /// 相邻帧配准失败时的兜底：把「上一锚帧」和「当前帧」分别对齐到已拼接
    /// 长图的尾部，取两个锚点之差作为位移。
    ///
    /// 原理：尾部像素来自已通过校验的拼接结果，干净且稳定。若当前帧顶部仍
    /// 与尾部强重叠，说明两帧之间的内容并没有漏——只是上一帧被动画/惯性/
    /// 懒加载弄脏而无法配准。此时以尾部为中介重新测位移，可零损失续接；
    /// 若真的跳过了内容，当前帧顶行对不上尾部，锚定自然失败、维持原失配
    /// 流程，不会错接。返回 nil 表示救不回来。
    private func recoverDisplacementFromStitchedTail(
        previousGray: GrayImage,
        currentGray: GrayImage,
        currentContent: CGImage
    ) -> Int? {
        guard stitchTailRows.count >= 24,
              previousGray.width == currentGray.width,
              previousGray.width > 0 else { return nil }

        // 尾部缓存是"每行 24 个采样"的行向量，当前帧也必须用同一套采样口径
        // 才能直接比对——早前这里拿行向量去比原始像素行，长度校验直接失败，
        // 整条自愈路径静默失效。
        let tailHeight = stitchTailRows.count
        let previousRows = Self.grayRowVectors(previousGray)
        let currentRows = Self.grayRowVectors(currentGray)
        guard tailHeight >= 24, !previousRows.isEmpty, !currentRows.isEmpty else { return nil }

        let minimumOverlap = max(16, currentGray.height / 6)
        // 上一锚帧按构造就是长图末尾几行的来源，锚点必须又准又稳；
        // 当前帧用与常规拼接一致的 18 分门槛。
        guard let previousAnchor = ScrollOverlapDetector.detectTailAnchor(
            tailRows: stitchTailRows,
            currentRows: previousRows,
            minimumOverlap: minimumOverlap,
            maximumDifference: 10
        ), let currentAnchor = ScrollOverlapDetector.detectTailAnchor(
            tailRows: stitchTailRows,
            currentRows: currentRows,
            minimumOverlap: minimumOverlap,
            maximumDifference: 18
        ) else { return nil }

        // 灰度行差 → 全分辨率内容行差（与常规位移同一量纲，
        // tracker.advance 的语义保持不变）。
        let grayToFull = CGFloat(currentContent.height) / CGFloat(max(currentGray.height, 1))
        let displacement = Int((CGFloat(currentAnchor.anchorRow - previousAnchor.anchorRow) * grayToFull).rounded())
        guard abs(displacement) < currentContent.height else { return nil }
        return displacement
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

        return rows
    }

    /// capcap 式滚动条检测：从最右列向左扫，找出两帧间持续变化、且变化区
    /// 之外归于安静的列带 = 滚动条滑块。要求"动→静"边界成立才采信，避免
    /// 把右侧恰好是动画的内容当成滚动条。
    private func detectScrollbar(previous: CGImage, current: CGImage) {
        let edgeWidth = 64
        guard let previousStrip = Self.grayEdgeStrip(image: previous, edgeWidth: edgeWidth),
              let currentStrip = Self.grayEdgeStrip(image: current, edgeWidth: edgeWidth),
              previousStrip.width == currentStrip.width,
              previousStrip.height == currentStrip.height else { return }
        let width = previousStrip.width
        let height = previousStrip.height
        guard width > 20, height > 40 else { return }
        scrollbarDetected = true

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

    private func postAutomaticScroll(multiplier: Int32 = 1, step: Int32? = nil) {
        guard let center = targetRectCenter else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -(step ?? automaticScrollStep) * multiplier,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = center
        // 滚轮事件不能用 postToPid：Chromium / Electron 的滚动区域不会处理
        // 这种进程定向事件，界面会显示“自动滚动中”但页面位置始终不变。
        // 目标应用已在开始和恢复时激活，光标也已锁到选区中心，因此从 HID
        // 事件流投递，和真实触控板/鼠标滚动的命中路径一致。
        event.post(tap: .cghidEventTap)
        let postedPoints = (step ?? automaticScrollStep) * multiplier
        automaticCommandedPointsSinceAnchor = min(
            Int32.max - postedPoints,
            automaticCommandedPointsSinceAnchor
        ) + postedPoints
    }

    private func switchToManual(reason: String) {
        mode = .manual
        automaticCommandedPointsSinceAnchor = 0
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

    private static func bodyIsStationaryIgnoringBorders(
        previous: GrayImage,
        current: GrayImage
    ) -> Bool {
        guard previous.width == current.width,
              previous.height == current.height else { return false }
        let width = previous.width
        let contentWidth = width - max(8, width / 16)
        // 原始帧实测：延迟卡片只在底栏上方 36px 窄带露出，正文没位移。
        // 跳过底部 8% 与右缘滚动条，同时仍检查约 90% 的主体内容。
        let contentHeight = previous.height - max(8, previous.height / 12)
        guard contentWidth > 0, contentHeight > 0 else { return false }
        let allowedChangedPixels = max(4, contentWidth * contentHeight / 2_000)
        var changedPixels = 0
        for row in 0..<contentHeight {
            let rowOffset = row * width
            for column in 0..<contentWidth {
                let index = rowOffset + column
                if abs(Int(previous.pixels[index]) - Int(current.pixels[index])) > 3 {
                    changedPixels += 1
                    if changedPixels > allowedChangedPixels { return false }
                }
            }
        }
        return true
    }

    /// 灰度缩略图的宽度上限。粗尺度（192）覆盖的位移范围大、速度快；
    /// 细尺度（480）量化误差小，用来在粗解附近做窄窗精修。
    private static let coarseGrayWidth = 192
    private static let fineGrayWidth = 480

    private static func grayscale(_ image: CGImage, width targetWidth: Int = 192) -> GrayImage? {
        let width = min(targetWidth, image.width)
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
        let images = renderedSegments
        guard let first = images.first else { return nil }
        let totalHeight = images.reduce(0) { $0 + $1.height }
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
        // 顶部固定栏、内容段、底部固定栏依次排列，各栏只画一次。
        var yUp: CGFloat = CGFloat(totalHeight)
        for segment in images {
            let h = CGFloat(segment.height)
            yUp -= h
            context.draw(segment, in: CGRect(x: 0, y: yUp, width: CGFloat(first.width), height: h))
        }
        return context.makeImage()
    }

    #if DEBUG
    /// 验收模式：写完验收图后不退出，把结果条留在屏幕上供人工/自动化检查。
    static var keepsAuditResultBarOpen = false

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
        let images = renderedSegments
        guard let first = images.first else {
            livePreviewImage = nil
            return
        }
        let totalHeight = images.reduce(0) { $0 + $1.height }
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
        segmentRows.reserveCapacity(images.count)
        for segment in images {
            cumulativeRows += segment.height
            let topRow = min(height, Int((CGFloat(cumulativeRows) * scale).rounded()))
            segmentRows.append((previousTopRow, topRow))
            previousTopRow = topRow
        }
        for (index, segment) in images.enumerated() {
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
        fixedBandsLocked = false
        fixedTopPx = 0
        fixedBottomPx = 0
        fixedHeaderImage = nil
        fixedFooterImage = nil
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
        automaticCommandedPointsSinceAnchor = 0
        lastUnchangedWasExact = false
        lastMismatchHadStationaryBody = false
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

    private func showControls(anchoredTo target: CGRect, in screen: CGRect) {
        let size = NSSize(width: 540, height: 54)
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
        // .screenSaver（层级 1000）高于普通应用窗口（0）：滚动截图全程目标应用
        // 在前台，这套浮层必须压在其上，用户才看得到"开始滚动"、实时预览，
        // 也点得到"完成"。别改成 maximumWindow——实测那样反而被选区浮层盖住。
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

private struct ScrollCaptureControlBarView: View {
    @State var controller: ScrollCaptureController

    var body: some View {
        HStack(spacing: 8) {
            // 状态文案并进控制条（飞书同款：运行态只有「预览 + 控制条」两块浮层，
            // 原来单独飘着的那条状态提示就是多余的一块）
            Text(controller.statusMessage)
                .font(RuneFont.swiftUI(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .leading)
                .accessibilityLabel(controller.statusMessage)

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

            Spacer(minLength: 6)

            // 段数与高度：原先挂在预览下面那个小胶囊，一并挪到控制条里
            Text(counterText)
                .font(RuneFont.mono(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
                .lineLimit(1)
                .accessibilityLabel(counterText)

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
                    Task { await controller.beginCapture() }
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
        .frame(width: 540, height: 52)
        .runeGlassSurface(cornerRadius: 12, elevation: .floating)
        .accessibilityElement(children: .contain)
    }

    /// 「N 段 · 高 XXX px」——预览里那块小胶囊的内容，挪到这里
    private var counterText: String {
        guard controller.stitchedHeight > 0 else { return "准备中" }
        let height: String
        if controller.stitchedHeight >= 10_000 {
            height = String(format: "%.1f万 px", Double(controller.stitchedHeight) / 10_000)
        } else {
            height = "\(controller.stitchedHeight) px"
        }
        return "\(controller.capturedFrameCount) 段 · \(height)"
    }
}
