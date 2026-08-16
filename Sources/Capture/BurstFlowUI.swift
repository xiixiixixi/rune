import AppKit

// MARK: - 连拍流程 UI：框选后的开始控制台 + 拍摄中的醒目状态条
// 纯 AppKit 实现（SwiftUI 宿主面板曾引发约束崩溃，全线弃用）。

/// 开始控制台：底部居中，白磨砂红白风。
/// [模式三选] [说明] [取消] [🔴 开始连拍]
@MainActor
final class BurstSetupPanelController {
    static let shared = BurstSetupPanelController()
    private var panel: NSPanel?
    private var modeControl: NSSegmentedControl?
    private var onBegin: ((BurstMode) -> Void)?

    private init() {}

    /// 显示控制台。selection 文本用于回显选区尺寸；onBegin=点开始（携带所选模式）。
    func show(regionSizeText: String, presetMode: BurstMode, onBegin: @escaping (BurstMode) -> Void) {
        dismiss()
        self.onBegin = onBegin

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 92),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 磨砂底
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 460, height: 92))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        panel.contentView = effect

        // 标题：选区回显
        let title = NSTextField(labelWithString: "连拍区域 \(regionSizeText) — 选好模式后点「开始」")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .white
        title.frame = NSRect(x: 18, y: 62, width: 424, height: 18)
        effect.addSubview(title)

        // 模式三选
        let seg = NSSegmentedControl(
            labels: ["连拍（最快）", "定数 10 张", "延时 5 秒/张"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        seg.selectedSegment = presetMode == .burst ? 0 : (presetMode == .fixedCount ? 1 : 2)
        seg.font = .systemFont(ofSize: 12, weight: .medium)
        seg.frame = NSRect(x: 18, y: 16, width: 268, height: 30)
        effect.addSubview(seg)
        modeControl = seg

        // 取消
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.font = .systemFont(ofSize: 12, weight: .medium)
        cancel.frame = NSRect(x: 294, y: 16, width: 58, height: 30)
        effect.addSubview(cancel)

        // 开始（红）
        let begin = NSButton(title: "开始连拍", target: self, action: #selector(beginTapped))
        begin.bezelStyle = .rounded
        begin.font = .systemFont(ofSize: 12, weight: .semibold)
        begin.contentTintColor = .white
        begin.layer?.backgroundColor = NSColor(red: 1.0, green: 0.231, blue: 0.189, alpha: 1).cgColor
        begin.wantsLayer = true
        begin.frame = NSRect(x: 356, y: 16, width: 86, height: 30)
        effect.addSubview(begin)

        if let sf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: sf.midX - 230, y: sf.minY + 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        modeControl = nil
        onBegin = nil
    }

    private var selectedMode: BurstMode {
        switch modeControl?.selectedSegment {
        case 1: .fixedCount
        case 2: .timelapse
        default: .burst
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {}

    @objc private func cancelTapped() { dismiss() }

    @objc private func beginTapped() {
        let mode = selectedMode
        dismiss()
        onBegin?(mode)
    }
}

/// 拍摄中状态条：顶部居中，黑底大字，一眼看懂"在拍/拍了 N 张/怎么停"。
@MainActor
final class BurstLiveBarController {
    static let shared = BurstLiveBarController()
    private var panel: NSPanel?
    private var countField: NSTextField?
    private var timer: Timer?

    private init() {}

    func show(mode: BurstMode, onStop: @escaping () -> Void) {
        dismiss()
        let modeText = mode == .burst ? "连拍中" : (mode == .fixedCount ? "定数拍摄中" : "延时拍摄中")

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        panel.contentView = effect

        // LIVE 红点+字
        let dot = NSView(frame: NSRect(x: 18, y: 24, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        effect.addSubview(dot)
        // 呼吸动画
        let dotAnim = CABasicAnimation(keyPath: "opacity")
        dotAnim.fromValue = 1.0
        dotAnim.toValue = 0.25
        dotAnim.duration = 0.6
        dotAnim.autoreverses = true
        dotAnim.repeatCount = .infinity
        dot.layer?.add(dotAnim, forKey: "pulse")

        let live = NSTextField(labelWithString: "LIVE · \(modeText)")
        live.font = .systemFont(ofSize: 12, weight: .semibold)
        live.textColor = .white
        live.frame = NSRect(x: 34, y: 8, width: 150, height: 16)
        effect.addSubview(live)

        // 大计数
        let count = NSTextField(labelWithString: "已拍 0 张")
        count.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        count.textColor = .white
        count.frame = NSRect(x: 34, y: 26, width: 200, height: 22)
        effect.addSubview(count)
        countField = count

        // 停止大按钮
        let stopBtn = NSButton(title: "关闭", target: self, action: #selector(stopTapped))
        stopBtn.bezelStyle = .rounded
        stopBtn.font = .systemFont(ofSize: 12, weight: .semibold)
        stopBtn.frame = NSRect(x: 258, y: 13, width: 104, height: 30)
        effect.addSubview(stopBtn)
        self.onStop = onStop

        if let sf = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: sf.midX - 190, y: sf.maxY - 68))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // 计数轮询（连拍帧率高，0.25s 刷新足够顺滑）
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.countField?.stringValue = "已拍 \(BurstCaptureController.shared.capturedCount) 张"
            }
        }
    }

    private var onStop: (() -> Void)?

    @objc private func stopTapped() {
        onStop?()
        dismiss()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        countField = nil
        onStop = nil
    }
}
