import AppKit
import SwiftUI

/// 截图确认模式控制器：截图后不落盘，冻结显示 + 底部工具栏，用户确认才保存。
///
/// 交互（docs/交互设计.md · 截图确认模式）：
/// - 全屏 OverlayWindow 显示刚截的图（屏幕冻结感）
/// - 屏幕底部居中浮起红白工具栏（标注/复制/贴图/取消/保存）
/// - Enter=保存、Esc=取消（零残留：不写文件、不建历史）
@MainActor
final class CaptureConfirmController: NSObject {
    static let shared = CaptureConfirmController()

    private var canvasWindow: OverlayWindow?
    private var toolbarPanel: NSPanel?
    private var continuation: CheckedContinuation<[AnnotationItem]?, Never>?

    /// 画布视图（弱引用供工具栏驱动）
    private(set) weak var canvas: ConfirmCanvasView?

    private override init() { super.init() }

    // MARK: - 入口

    /// 进入确认模式。
    /// - Parameters:
    ///   - image: 截好的图（CGImage）
    ///   - screen: 截图所在屏（工具栏贴这个屏的底部）
    /// - Returns: 用户确认时返回标注列表（可为空数组=不带标注保存）；取消返回 nil
    func present(image: CGImage, on screen: NSScreen?) async -> [AnnotationItem]? {
        // 防重入：已有确认会话时直接取消新的
        guard continuation == nil else { return nil }

        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first!

        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.showWindows(image: image, on: targetScreen)
        }
    }

    // MARK: - 窗口搭建

    private func showWindows(image: CGImage, on screen: NSScreen) {
        let canvas = ConfirmCanvasView(image: image, screen: screen, controller: self)
        let window = OverlayWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)

        canvasWindow = window
        self.canvas = canvas

        // 底部工具栏（同 BurstStatusBar 的 NSPanel 配方，改贴屏幕底部）
        let toolbar = ConfirmToolbarView(controller: self)
        let panel = ToolbarPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 620, height: QJTheme.barHeight)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: toolbar)

        // 贴屏幕底部居中（留 20pt 边距）
        let size = panel.contentRect(forFrameRect: panel.frame).size
        let sf = screen.visibleFrame
        panel.setFrame(NSRect(
            x: sf.midX - size.width / 2,
            y: sf.minY + 20,
            width: size.width,
            height: size.height
        ), display: true)
        panel.orderFrontRegardless()

        toolbarPanel = panel
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 结束

    /// 用户点保存/按 Enter。
    func confirm() {
        let items = canvas?.annotations ?? []
        finish(result: items)
    }

    /// 用户点取消/按 Esc。零残留。
    func cancel() {
        finish(result: nil)
    }

    private func finish(result: [AnnotationItem]?) {
        closeWindows()
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    private func closeWindows() {
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        canvasWindow?.orderOut(nil)
        canvasWindow = nil
        canvas = nil
    }
}

// MARK: - 窗口子类

/// 全屏画布窗：照 RegionSelectionOverlay.OverlayWindow 的配方（可成为 key 才能收键盘）。
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cursorUpdate(with event: NSEvent) {}
}

/// 底部工具栏面板：nonactivating 不抢画布焦点；点击按钮仍可触发（SwiftUI 按钮）。
private final class ToolbarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}
