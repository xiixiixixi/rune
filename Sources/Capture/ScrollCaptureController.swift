import AppKit
import CaptureKit
import CaptureKitSCK
import SwiftUI

/// 滚动截图：用户框选一个滚动区域后，Rune定时抓取该区域；用户向下滚动页面，
/// 程序自动找出相邻画面的重叠部分，只把新出现的底部内容接到长图末尾。
@MainActor
@Observable
final class ScrollCaptureController {
    static let shared = ScrollCaptureController()

    private(set) var isActive = false
    private var isPreparing = false
    private(set) var capturedFrameCount = 0
    private(set) var stitchedHeight = 0
    private(set) var statusMessage = "请选择要滚动的区域"

    private let engine = SCKStillCaptureBackend()
    /// 半自动收尾：用户手动滚，静止（到底）约 2.8 秒自动生成长图。
    /// 注：原"程序代滚"方案经实测不可行——合成滚轮事件在本机对所有应用均无效
    /// （原生窗口 0% 响应，三组对照验证），保留用户滚+静止自动收。
    private var autoScroll = false
    private var staleRounds = 0
    private var captureTask: Task<Void, Never>?
    private var targetRect: CGRect?
    private var previousImage: CGImage?
    private var segments: [CGImage] = []
    private var scaleFactor: CGFloat = 1
    private var displayID: CGDirectDisplayID?

    private init() {}

    func start(on screen: NSScreen? = nil, presetRegion: CGRect? = nil) async {
        guard !isActive, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        guard await ScreenCapturePermissionController.shared.ensurePermission(
            for: .scrollCapture,
            on: screen
        ) else { return }

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
        staleRounds = 0
        statusMessage = "请向下滚动，到底后自动生成长图"
        captureTask?.cancel()
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, self.isActive else { break }
                let grew = await self.captureNextFrame()
                // 连续 8 轮（≈2.8s）没有新内容 → 判定到底/用户停手，自动生成长图
                if grew { self.staleRounds = 0 } else {
                    self.staleRounds += 1
                    if self.staleRounds >= 8 {
                        await self.stop()
                        break
                    }
                }
            }
        }
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
            statusMessage = "已拼接 \(capturedFrameCount) 屏，高度 \(stitchedHeight) 像素（到底自动完成）"
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
        let view = ScrollCaptureStatusBarView(controller: .shared)
        let hosting = NSHostingView(rootView: view.runeTypography())
        // 状态变化时宽度保持不跳动，避免用户滚动过程中按钮来回移动。
        let size = NSSize(width: 540, height: 60)
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
    }

    func confirmAndCancel() {
        let count = ScrollCaptureController.shared.capturedFrameCount
        let alert = NSAlert()
        alert.messageText = "放弃这次滚动截图？"
        alert.informativeText = count > 1
            ? "已经拼接的 \(count) 屏内容不会保存。"
            : "当前画面不会保存。"
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "继续滚动")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ScrollCaptureController.shared.cancel()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScrollCaptureStatusBarView: View {
    @State var controller: ScrollCaptureController

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(RuneFont.swiftUI(size: 17, weight: .semibold))
                .foregroundStyle(RuneTheme.accent)
                .frame(width: 30, height: 30)
                .background(RuneTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .help("滚动截图进行中")

            VStack(alignment: .leading, spacing: 3) {
                Text("正在拼接长图")
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                Text(controller.statusMessage)
                    .font(RuneFont.swiftUI(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(controller.capturedFrameCount) 屏")
                .font(RuneFont.swiftUI(size: 13, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 42, alignment: .trailing)

            Menu {
                Button("放弃这次长图…", systemImage: "trash", role: .destructive) {
                    ScrollCaptureStatusBarController.shared.confirmAndCancel()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(RuneFont.swiftUI(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("更多滚动截图操作")

            Spacer()

            Button {
                Task { await controller.stop() }
            } label: {
                RuneTheme.primaryButtonLabel("完成")
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .help("结束滚动，把已抓的画面拼成一张长图")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
    }
}
