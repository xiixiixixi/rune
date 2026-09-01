import AppKit
import CaptureKit
import CaptureKitSCK
import SwiftUI

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

/// 滚动截图：框选滚动内容后优先自动向下滚动，无法注入滚动事件时自动降级为
/// 手动模式。两种模式都用相邻帧重叠检测，只追加真正新出现的底部内容。
@MainActor
@Observable
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private(set) var isActive = false
    private var isPreparing = false
    private(set) var capturedFrameCount = 0
    private(set) var stitchedHeight = 0
    private(set) var statusMessage = "请选择要滚动的区域"
    private(set) var mode: ScrollCaptureMode = .automatic
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
    private var scaleFactor: CGFloat = 1
    private var displayID: CGDirectDisplayID?
    private var unchangedRounds = 0
    private var mismatchRounds = 0
    private var hasObservedGrowth = false
    private var originalCursorLocation: CGPoint?
    private var cursorHiddenOnDisplay: CGDirectDisplayID?

    private enum FrameCaptureResult {
        case appended
        case unchanged
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
        guard !isActive, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .scrollCapture,
            on: screen
        ) else { return }

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
        mode = UIElementDetector.isTrusted && targetProcessID != nil ? .automatic : .manual
        isActive = true
        isPaused = false
        isFinishing = false
        isAwaitingStart = true
        capturedFrameCount = 0
        stitchedHeight = 0
        livePreviewImage = nil
        statusMessage = "区域已锁定，正在准备长图"

        ScrollCaptureStatusBarController.shared.show(on: screen, targetRect: pointsRect)
        activateTargetApplication()

        // 等待目标应用重新成为前台，也确保选区/确认蒙层已从 WindowServer 退场。
        try? await Task.sleep(for: .milliseconds(180))
        guard isActive else { return }

        do {
            let first = try await engine.capture(.region(pointsRect))
            // 首帧抓取期间用户仍可按 Esc；若已取消，不得把迟到的帧重新写回状态。
            guard isActive else { return }
            previousImage = first.image
            segments = [first.image]
            scaleFactor = first.scaleFactor
            displayID = first.displayID
            capturedFrameCount = 1
            stitchedHeight = first.image.height
            updateLivePreview()
            statusMessage = mode == .automatic
                ? "点击“开始滚动”，或先调整到内容顶部"
                : "点击“开始滚动”，随后在选区内慢慢滚动"
        } catch {
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
        hasObservedGrowth = false
        if mode == .automatic {
            prepareAutomaticCursor()
            statusMessage = "自动向下滚动中；可随时暂停或完成"
        } else {
            statusMessage = manualCaptureInstruction
        }
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
        statusMessage = "正在生成长图…"
        ScrollCaptureStatusBarController.shared.dismiss()

        guard let image = renderSegments() else {
            isFinishing = false
            reset()
            showError("长图生成失败，请重试。")
            return
        }
        let frame = CapturedFrame(
            image: image,
            scaleFactor: scaleFactor,
            displayID: displayID
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
            statusMessage = "自动滚动需要辅助功能权限；当前继续手动捕获"
            return
        }

        mode = .automatic
        isPaused = false
        unchangedRounds = 0
        mismatchRounds = 0
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
        hasObservedGrowth = false
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard !Task.isCancelled, let self, self.isActive else { break }

                if self.isPaused {
                    try? await Task.sleep(for: .milliseconds(180))
                    continue
                }

                if self.mode == .automatic {
                    self.postAutomaticScroll()
                    try? await Task.sleep(for: .milliseconds(420))
                } else {
                    try? await Task.sleep(for: .milliseconds(260))
                }
                guard !Task.isCancelled, self.isActive else { break }

                switch await self.captureNextFrame() {
                case .appended:
                    self.hasObservedGrowth = true
                    self.unchangedRounds = 0
                    self.mismatchRounds = 0

                case .unchanged:
                    guard self.mode == .automatic else { continue }
                    self.unchangedRounds += 1
                    if self.hasObservedGrowth, self.unchangedRounds >= 5 {
                        await self.stop()
                        return
                    }
                    if !self.hasObservedGrowth, self.unchangedRounds >= 5 {
                        self.switchToManual(
                            reason: "目标应用没有响应自动滚动，已切到手动模式"
                        )
                    }

                case .mismatch:
                    self.mismatchRounds += 1
                    if self.mode == .automatic, self.mismatchRounds >= 3 {
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
                    if self.mode == .manual {
                        self.statusMessage = "暂时没有抓到画面；可继续滚动或点完成"
                    }
                }
            }
        }
    }

    private func captureNextFrame() async -> FrameCaptureResult {
        guard let targetRect, let previousImage else { return .failed }
        do {
            let next = try await engine.capture(.region(targetRect))
            guard next.image.width == previousImage.width,
                  next.image.height == previousImage.height,
                  let previousGray = grayscale(previousImage),
                  let currentGray = grayscale(next.image),
                  previousGray.width == currentGray.width,
                  previousGray.height == currentGray.height else {
                statusMessage = "画面尺寸发生变化，请保持窗口大小不变"
                return .mismatch
            }

            guard let sampledRows = ScrollOverlapDetector.appendedRowCount(
                previous: previousGray.pixels,
                current: currentGray.pixels,
                width: previousGray.width,
                height: previousGray.height
            ) else {
                return .mismatch
            }
            guard sampledRows > 0 else { return .unchanged }

            let appendedRows = max(1, Int(
                (CGFloat(sampledRows) / CGFloat(previousGray.height) * CGFloat(next.image.height)).rounded()
            ))
            guard stitchedHeight + appendedRows <= 100_000 else {
                statusMessage = "长图已达到 100000 像素，正在生成当前内容"
                return .limitReached
            }
            let cropRect = CGRect(
                x: 0,
                y: next.image.height - appendedRows,
                width: next.image.width,
                height: appendedRows
            )
            guard let newBottom = next.image.cropping(to: cropRect) else { return .failed }
            segments.append(newBottom)
            self.previousImage = next.image
            capturedFrameCount += 1
            stitchedHeight += appendedRows
            updateLivePreview()
            statusMessage = mode == .automatic
                ? "自动滚动中：已拼接 \(capturedFrameCount) 段"
                : "手动滚动中：已拼接 \(capturedFrameCount) 段"
            return .appended
        } catch {
            return .failed
        }
    }

    private var targetRectCenter: CGPoint? {
        targetRect.map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private var manualCaptureInstruction: String {
        UIElementDetector.isTrusted
            ? "请在选区内向下滚动；Esc 或“完成”收尾"
            : "请在选区内向下滚动；点“完成”收尾"
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

    private func postAutomaticScroll() {
        guard let center = targetRectCenter else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: -140,
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

    private func grayscale(_ image: CGImage) -> GrayImage? {
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
        var y = CGFloat(height)
        for segment in segments {
            let segmentHeight = CGFloat(segment.height) * scale
            y -= segmentHeight
            context.draw(
                segment,
                in: CGRect(
                    x: 0,
                    y: y,
                    width: CGFloat(segment.width) * scale,
                    height: segmentHeight
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
        capturedFrameCount = 0
        stitchedHeight = 0
        unchangedRounds = 0
        mismatchRounds = 0
        hasObservedGrowth = false
        mode = .automatic
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
