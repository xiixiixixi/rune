import AppKit
import SwiftUI

/// 金手指进行中的浮动计数器 UI（参考 RecordingStatusBar 的 NSPanel 模式，更简）。
/// 显示：已抓 N 张 / 模式 / 停止按钮。
/// 宽度由 fittingSize 驱动（张数变多时面板跟着变宽，杜绝写死宽度被裁）。
@MainActor
final class BurstStatusBarController {
    static let shared = BurstStatusBarController()
    private var panel: NSPanel?

    private init() {}

    func show(on screen: NSScreen? = nil) {
        dismiss()
        let controller = BurstCaptureController.shared
        let view = BurstStatusBarView(
            count: { controller.capturedCount },
            mode: { controller.currentMode },
            onStop: { [weak self] in self?.dismiss(); controller.stop() },
            onWidthChange: { [weak self] in self?.relayout() }
        )
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: ceil(hosting.fittingSize.width), height: 40)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        // 放在屏幕顶部居中
        if let sf = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2, y: sf.maxY - size.height - 12))
        }
        panel.orderFront(nil)
        self.panel = panel
    }

    /// 内容变宽（张数增多）时按 fittingSize 重新居中
    private func relayout() {
        guard let panel,
              let hosting = panel.contentView as? NSHostingView<BurstStatusBarView> else { return }
        let width = ceil(hosting.fittingSize.width)
        guard width > 30, width != panel.frame.width else { return }
        let x = panel.frame.midX - width / 2
        panel.setFrame(NSRect(x: x, y: panel.frame.minY, width: width, height: panel.frame.height), display: true)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct BurstStatusBarView: View {
    let count: () -> Int
    let mode: () -> BurstMode
    let onStop: () -> Void
    let onWidthChange: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: .orange.opacity(0.5), radius: pulse ? 4 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            Label("\(count()) 张", systemImage: "camera.fill")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .help("已抓取的照片张数")

            Text(modeLabel)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
                .help(modeHelp)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("停止连拍，已抓的照片进入确认")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: count()) { _, _ in onWidthChange() }
    }

    private var modeLabel: String {
        switch mode() {
        case .burst: "连拍"
        case .fixedCount: "定数"
        case .timelapse: "延时"
        }
    }

    private var modeHelp: String {
        switch mode() {
        case .burst: "连拍模式：一直拍，直到你点停止"
        case .fixedCount: "定数模式：拍满设定张数自动停"
        case .timelapse: "延时模式：按间隔定时拍一张"
        }
    }
}
