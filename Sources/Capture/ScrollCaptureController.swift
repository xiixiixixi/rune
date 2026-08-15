import AppKit
import CaptureKit
import CaptureKitSCK
import SwiftUI

/// 滚动截图：用户框选一个滚动区域后，轻截定时抓取该区域；用户向下滚动页面，
/// 程序自动找出相邻画面的重叠部分，只把新出现的底部内容接到长图末尾。
@MainActor
@Observable
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private(set) var isActive = false
    private(set) var capturedFrameCount = 0
    private(set) var stitchedHeight = 0
    private(set) var statusMessage = "请选择要滚动的区域"

    private let engine = SCKStillCaptureBackend()
    /// 钉钉式自动滚动：轮询时自动发滚轮；连续多次无新内容=到底，自动生成
    private var autoScroll = true
    private var staleRounds = 0
    private var captureTask: Task<Void, Never>?
    private var targetRect: CGRect?
    private var previousImage: CGImage?
    private var segments: [CGImage] = []
    private var scaleFactor: CGFloat = 1
    private var displayID: CGDirectDisplayID?

    private init() {}

    func start(on screen: NSScreen? = nil, presetRegion: CGRect? = nil) async {
        guard !isActive else { return }
        guard requestPermissionIfNeeded() else { return }

        // 预设选区（从确认画面「滚动长图」转入）时跳过框选
        var pointsRect = presetRegion
        if pointsRect == nil {
            statusMessage = "请框选需要滚动的内容"
            guard let selection = await RegionSelectionOverlay().selectRegion() else { return }
            pointsRect = selection.pointsRect
        }
        guard let pointsRect else { return }

        do {
            let first = try await engine.capture(.region(pointsRect))
            targetRect = pointsRect
            previousImage = first.image
            segments = [first.image]
            scaleFactor = first.scaleFactor
            displayID = first.displayID
            capturedFrameCount = 1
            stitchedHeight = first.image.height
            isActive = true
            statusMessage = "请缓慢向下滚动，完成后点“生成长图”"
            ScrollCaptureStatusBarController.shared.show(on: screen)
            beginPolling()
        } catch {
            statusMessage = "滚动截图启动失败"
            showError("无法开始滚动截图：\(error.localizedDescription)")
        }
    }

    func stop() async {
        guard isActive else { return }
        autoScroll = false
        isActive = false
        captureTask?.cancel()
        captureTask = nil
        ScrollCaptureStatusBarController.shared.dismiss()

        guard let image = renderSegments() else {
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
        autoScroll = false
        captureTask?.cancel()
        captureTask = nil
        isActive = false
        ScrollCaptureStatusBarController.shared.dismiss()
        reset()
    }

    private func beginPolling() {
        autoScroll = true
        staleRounds = 0
        statusMessage = "自动滚动中…到底自动完成（也可手动滚）"
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, self.isActive else { break }
                // 自动滚：向选区中心发一次小步滚轮（与轮询同步，不会滚过头）
                if self.autoScroll { Self.postScrollWheel(at: self.targetRectCenter) }
                let grew = await self.captureNextFrame()
                // 连续 4 轮（≈1.4s）没有新内容 → 判定到底，自动生成长图
                if grew { self.staleRounds = 0 } else {
                    self.staleRounds += 1
                    if self.staleRounds >= 4, self.autoScroll {
                        await self.stop()
                        break
                    }
                }
            }
        }
    }

    private var targetRectCenter: CGPoint? {
        guard let targetRect else { return nil }
        // CG 全局坐标（左上原点）→ CGEvent 用同一坐标系
        return CGPoint(x: targetRect.midX, y: targetRect.midY)
    }

    /// 向指定位置发一次向下的滚轮事件（自动滚动）。
    private static func postScrollWheel(at point: CGPoint?) {
        guard let point else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                              wheel1: -90, wheel2: 0, wheel3: 0) else { return }
        // 位置设为选区中心：滚轮作用于该点下的窗口（否则滚的是鼠标所在处）
        e.location = point
        e.post(tap: .cghidEventTap)
    }

    @discardableResult
    private func captureNextFrame() async -> Bool {
        guard let targetRect, let previousImage else { return false }
        do {
            let next = try await engine.capture(.region(targetRect))
            guard next.image.width == previousImage.width,
                  next.image.height == previousImage.height,
                  let previousGray = grayscale(previousImage),
                  let currentGray = grayscale(next.image),
                  previousGray.width == currentGray.width,
                  previousGray.height == currentGray.height else {
                statusMessage = "画面尺寸发生变化，请保持窗口大小不变"
                return false
            }

            guard let sampledRows = ScrollOverlapDetector.appendedRowCount(
                previous: previousGray.pixels,
                current: currentGray.pixels,
                width: previousGray.width,
                height: previousGray.height
            ) else {
                statusMessage = "没有找到重叠内容，请滚动慢一点"
                return false
            }
            guard sampledRows > 0 else { return false }   // 静止：无新内容

            let appendedRows = max(1, Int(
                (CGFloat(sampledRows) / CGFloat(previousGray.height) * CGFloat(next.image.height)).rounded()
            ))
            guard stitchedHeight + appendedRows <= 60_000 else {
                statusMessage = "长图已达到 60000 像素，请生成当前长图"
                return false
            }
            let cropRect = CGRect(
                x: 0,
                y: next.image.height - appendedRows,
                width: next.image.width,
                height: appendedRows
            )
            guard let newBottom = next.image.cropping(to: cropRect) else { return false }
            segments.append(newBottom)
            self.previousImage = next.image
            capturedFrameCount += 1
            stitchedHeight += appendedRows
            statusMessage = "自动滚动中：已拼接 \(capturedFrameCount) 屏，高度 \(stitchedHeight) 像素"
            return true
        } catch {
            statusMessage = "抓取画面失败，请稍后重试"
            return false
        }
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

    private func requestPermissionIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        _ = CGRequestScreenCaptureAccess()
        if CGPreflightScreenCaptureAccess() { return true }
        showError("请在系统设置的「隐私与安全性 > 屏幕与系统音频录制」中允许“轻截”，然后重新打开轻截。")
        return false
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
        previousImage = nil
        segments.removeAll()
        capturedFrameCount = 0
        stitchedHeight = 0
        if !keepStatus { statusMessage = "请选择要滚动的区域" }
    }
}

@MainActor
final class ScrollCaptureStatusBarController {
    static let shared = ScrollCaptureStatusBarController()
    private var panel: NSPanel?

    private init() {}

    func show(on screen: NSScreen? = nil) {
        dismiss()
        let view = ScrollCaptureStatusBarView(
            controller: .shared,
            onWidthChange: { [weak self] in self?.relayout() }
        )
        let hosting = NSHostingView(rootView: view)
        // 宽度自适应：文字变长面板跟着变宽（上限 620，超长才截断），杜绝写死 410pt 截字
        let width = min(ceil(hosting.fittingSize.width), 620)
        let size = NSSize(width: width, height: 48)
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
        panel.orderFront(nil)
        self.panel = panel
    }

    /// 状态文字变化时按 fittingSize 重新居中（顶部锚定）
    private func relayout() {
        guard let panel,
              let hosting = panel.contentView as? NSHostingView<ScrollCaptureStatusBarView> else { return }
        let width = min(ceil(hosting.fittingSize.width), 620)
        guard width > 60, abs(width - panel.frame.width) > 0.5 else { return }
        let x = panel.frame.midX - width / 2
        panel.setFrame(NSRect(x: x, y: panel.frame.minY, width: width, height: panel.frame.height), display: true)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScrollCaptureStatusBarView: View {
    @State var controller: ScrollCaptureController
    var onWidthChange: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(.orange)
                .help("滚动截图进行中")
            Text(controller.statusMessage)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Button("取消") { controller.cancel() }
                .buttonStyle(.borderless)
                .help("放弃本次滚动截图（不保存）")
            Button("生成长图") {
                Task { await controller.stop() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("结束滚动，把已抓的画面拼成一张长图")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: controller.statusMessage) { _, _ in onWidthChange() }
    }
}
