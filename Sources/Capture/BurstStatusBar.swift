import AppKit
import SwiftUI

/// 金手指进行中的浮动计数器 UI（参考 RecordingStatusBar 的 NSPanel 模式，更简）。
/// 显示：已抓 N 张 / 帧率 / 停止按钮。
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
            onStop: { [weak self] in self?.dismiss(); controller.stop() }
        )
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 180, height: 36)
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

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct BurstStatusBarView: View {
    let count: () -> Int
    let mode: () -> BurstMode
    let onStop: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: .orange.opacity(0.5), radius: pulse ? 4 : 1)
                .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }

            Text("📸 \(count())")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)

            Text(modeLabel)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))

            Spacer()

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    private var modeLabel: String {
        switch mode() {
        case .burst: "连拍"
        case .fixedCount: "定数"
        case .timelapse: "延时"
        }
    }
}
