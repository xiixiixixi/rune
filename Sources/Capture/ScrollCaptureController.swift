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
        capturedFrameCount = 0
        stitchedHeight = 0
        statusMessage = mode == .automatic
            ? "区域已锁定，正在准备自动滚动"
            : "区域已锁定，请在选区内向下滚动"

        ScrollCaptureStatusBarController.shared.show(on: screen)
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
            if mode == .automatic {
                prepareAutomaticCursor()
                statusMessage = "自动向下滚动中；Esc 可提前完成"
            } else {
                statusMessage = manualCaptureInstruction
            }
            beginPolling()
        } catch {
            isActive = false
            ScrollCaptureStatusBarController.shared.dismiss()
            restoreAutomaticCursor()
            reset()
            statusMessage = "滚动截图启动失败"
            showError("无法开始滚动截图：\(error.localizedDescription)")
        }
    }

    func stop() async {
        guard isActive, !isFinishing else { return }
        guard !segments.isEmpty else {
            cancel()
            return
        }
        isFinishing = true
        isActive = false
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
        restoreAutomaticCursor()
        ScrollCaptureStatusBarController.shared.dismiss()
        reset()
    }

    func togglePause() {
        guard isActive, !isFinishing else { return }
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
        prepareAutomaticCursor()
        activateTargetApplication()
        statusMessage = "自动向下滚动中；Esc 可提前完成"
    }

    func resumeAfterDialog() {
        guard isActive else { return }
        activateTargetApplication()
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
        if let targetProcessID {
            event.postToPid(targetProcessID)
        } else {
            event.post(tap: .cghidEventTap)
        }
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
        if !keepStatus { statusMessage = "请选择要滚动的区域" }
    }
}

@MainActor
final class ScrollCaptureStatusBarController {
    static let shared = ScrollCaptureStatusBarController()
    private var panel: NSPanel?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private init() {}

    func show(on screen: NSScreen? = nil) {
        dismiss()
        let view = ScrollCaptureStatusBarView(controller: .shared)
            .environment(\.colorScheme, .dark)
        let hosting = NSHostingView(rootView: view.runeTypography())
        // 状态变化时宽度保持不跳动，避免用户滚动过程中按钮来回移动。
        let size = NSSize(width: 620, height: 64)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        if let frame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        installEscapeMonitors()
    }

    func confirmAndCancel() {
        // 警告框里的 Esc 表示继续，不能同时被全局监听器解释为生成长图。
        removeEscapeMonitors()
        let count = ScrollCaptureController.shared.capturedFrameCount
        let alert = NSAlert()
        alert.messageText = "放弃这次滚动截图？"
        alert.informativeText = count > 1
            ? "已经拼接的 \(count) 段内容不会保存。"
            : "当前画面不会保存。"
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "继续滚动")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            ScrollCaptureController.shared.cancel()
        } else {
            installEscapeMonitors()
            ScrollCaptureController.shared.resumeAfterDialog()
        }
    }

    func dismiss() {
        removeEscapeMonitors()
        panel?.orderOut(nil)
        panel = nil
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                await ScrollCaptureController.shared.stop()
            }
            return nil
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in
                await ScrollCaptureController.shared.stop()
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

private struct ScrollCaptureStatusBarView: View {
    @State var controller: ScrollCaptureController

    var body: some View {
        HStack(spacing: 12) {
            RuneOpticalIconPlate(systemImage: "rectangle.stack", size: 30)
                .help("滚动截图进行中")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("滚动长图")
                        .font(RuneFont.swiftUI(size: 12, weight: .semibold))

                    Label(controller.mode.label, systemImage: controller.mode.systemImage)
                        .font(RuneFont.swiftUI(size: 9.5, weight: .medium))
                        .foregroundStyle(
                            controller.mode == .automatic
                                ? RuneTheme.cyan
                                : RuneTheme.textSecondary
                        )
                }
                Text(controller.statusMessage)
                    .font(RuneFont.swiftUI(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(controller.capturedFrameCount) 段")
                    .font(RuneFont.mono(size: 11.5, weight: .semibold))
                Text(heightText)
                    .font(RuneFont.mono(size: 8.5, weight: .medium))
                    .foregroundStyle(RuneTheme.textMuted)
            }
            .frame(minWidth: 70, alignment: .trailing)

            RuneMenu(
                surface: .chrome,
                entries: {
                    [
                        .item(
                            RuneMenuItem(
                                controller.mode == .automatic
                                    ? "切换为手动滚动"
                                    : "切换为自动滚动",
                                systemImage: controller.mode == .automatic
                                    ? "hand.draw"
                                    : "arrow.down.to.line.compact"
                            ) {
                                controller.toggleMode()
                            }
                        ),
                        .divider,
                        .item(
                            RuneMenuItem("放弃这次长图…", systemImage: "trash", isDestructive: true) {
                                ScrollCaptureStatusBarController.shared.confirmAndCancel()
                            }
                        ),
                    ]
                }
            ) {
                Image(systemName: "ellipsis.circle")
                    .font(RuneFont.swiftUI(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .help("更多滚动截图操作")

            Button {
                controller.togglePause()
            } label: {
                Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .foregroundStyle(RuneTheme.textPrimary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.capturedFrameCount == 0 || controller.isFinishing)
            .help(controller.isPaused ? "继续滚动截图" : "暂停滚动截图")
            .accessibilityLabel(controller.isPaused ? "继续滚动截图" : "暂停滚动截图")

            Button {
                Task { await controller.stop() }
            } label: {
                RuneTheme.primaryButtonLabel("完成")
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .disabled(controller.capturedFrameCount == 0 || controller.isFinishing)
            .help("结束滚动，把已抓的画面拼成一张长图")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .runeGlassSurface(cornerRadius: RuneTheme.barCorner, elevation: .floating)
        .accessibilityElement(children: .contain)
    }

    private var heightText: String {
        guard controller.stitchedHeight > 0 else { return "准备中" }
        if controller.stitchedHeight >= 10_000 {
            return String(format: "%.1f 万 px", Double(controller.stitchedHeight) / 10_000)
        }
        return "\(controller.stitchedHeight) px"
    }
}
