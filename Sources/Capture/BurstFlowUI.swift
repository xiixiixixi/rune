import AppKit

// MARK: - 连拍准备面板

/// 框选后出现的准备面板：模式、关键参数和开始动作一次说清。
@MainActor
final class BurstSetupPanelController {
    static let shared = BurstSetupPanelController()

    private var panel: NSWindow?
    private var modeControl: NSSegmentedControl?
    private var valueField: NSTextField?
    private var valueStepper: NSStepper?
    private var detailField: NSTextField?
    private var keyMonitor: Any?
    private var onBegin: ((BurstMode) -> Void)?

    private init() {}

    func show(
        regionSizeText: String,
        presetMode: BurstMode,
        on screen: NSScreen? = nil,
        onBegin: @escaping (BurstMode) -> Void
    ) {
        dismiss()
        self.onBegin = onBegin

        let panelSize = NSSize(width: 520, height: 148)
        let (panel, isInteractiveAudit) = makeBurstPanel(
            size: panelSize,
            auditTitle: "Rune 连拍准备"
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = isInteractiveAudit
            ? .normal
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        panel.contentView = effect

        let icon = NSImageView(frame: NSRect(x: 18, y: 110, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "连拍")
        icon.contentTintColor = .systemRed
        effect.addSubview(icon)

        let title = NSTextField(labelWithString: "准备连拍")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor
        title.frame = NSRect(x: 48, y: 112, width: 180, height: 20)
        effect.addSubview(title)

        let region = NSTextField(labelWithString: "区域 \(regionSizeText)")
        region.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        region.textColor = .secondaryLabelColor
        region.alignment = .right
        region.frame = NSRect(x: 322, y: 113, width: 180, height: 18)
        region.setAccessibilityLabel("连拍区域尺寸 \(regionSizeText)")
        effect.addSubview(region)

        let subtitle = NSTextField(labelWithString: "选一种拍法；开始后会一直显示张数，并可暂停或结束")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 18, y: 88, width: 484, height: 17)
        effect.addSubview(subtitle)

        let segments = NSSegmentedControl(
            labels: ["连续", "定数", "延时"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        segments.selectedSegment = presetMode.segmentIndex
        segments.font = .systemFont(ofSize: 12, weight: .medium)
        segments.frame = NSRect(x: 18, y: 46, width: 246, height: 30)
        segments.setAccessibilityLabel("连拍拍摄方式")
        effect.addSubview(segments)
        modeControl = segments

        let value = NSTextField(labelWithString: "10")
        value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        value.textColor = .labelColor
        value.alignment = .right
        value.frame = NSRect(x: 18, y: 17, width: 38, height: 20)
        effect.addSubview(value)
        valueField = value

        let stepper = NSStepper(frame: NSRect(x: 62, y: 14, width: 18, height: 24))
        stepper.target = self
        stepper.action = #selector(valueChanged(_:))
        stepper.autorepeat = true
        stepper.valueWraps = false
        stepper.setAccessibilityLabel("调整连拍参数")
        effect.addSubview(stepper)
        valueStepper = stepper

        let detail = NSTextField(labelWithString: "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 90, y: 18, width: 236, height: 18)
        effect.addSubview(detail)
        detailField = detail

        let cancel = makePanelButton(
            title: "取消",
            frame: NSRect(x: 352, y: 17, width: 64, height: 34),
            accent: false,
            target: self,
            action: #selector(cancelTapped)
        )
        cancel.setAccessibilityLabel("取消连拍")
        effect.addSubview(cancel)

        let begin = makePanelButton(
            title: "开始",
            frame: NSRect(x: 424, y: 17, width: 78, height: 34),
            accent: true,
            target: self,
            action: #selector(beginTapped)
        )
        begin.setAccessibilityLabel("开始连拍")
        effect.addSubview(begin)

        updateModeUI()

        if let screenFrame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screenFrame.midX - panelSize.width / 2, y: screenFrame.minY + 24))
        }
        panel.orderFrontRegardless()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-burst-setup")
            || ProcessInfo.processInfo.arguments.contains("--audit-burst-interactive") {
            panel.makeKeyAndOrderFront(nil)
        }
        #endif
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.dismiss()
            return nil
        }
    }

    func dismiss() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        modeControl = nil
        valueField = nil
        valueStepper = nil
        detailField = nil
        onBegin = nil
    }

    private var selectedMode: BurstMode {
        BurstMode(segmentIndex: modeControl?.selectedSegment ?? 0)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        updateModeUI()
    }

    @objc private func valueChanged(_ sender: NSStepper) {
        let value = Int(sender.integerValue)
        let controller = BurstCaptureController.shared
        switch selectedMode {
        case .burst:
            controller.fps = value
        case .fixedCount:
            controller.fixedCount = value
        case .timelapse:
            controller.timelapseInterval = TimeInterval(value)
        }
        updateModeUI()
    }

    private func updateModeUI() {
        guard let valueStepper else { return }
        let controller = BurstCaptureController.shared
        let value: Int
        let range: ClosedRange<Double>
        let detail: String

        switch selectedMode {
        case .burst:
            value = controller.fps
            range = 1...30
            detail = "帧/秒 · 最多 \(controller.burstLimit) 张"
            valueStepper.setAccessibilityLabel("调整连续拍摄速度")
        case .fixedCount:
            value = controller.fixedCount
            range = 2...100
            detail = "张后自动停止 · \(controller.fps) 帧/秒"
            valueStepper.setAccessibilityLabel("调整拍摄张数")
        case .timelapse:
            value = max(1, Int(controller.timelapseInterval))
            range = 1...60
            detail = "秒一张 · 最多 \(controller.timelapseLimit) 张"
            valueStepper.setAccessibilityLabel("调整拍摄间隔")
        }

        valueStepper.minValue = range.lowerBound
        valueStepper.maxValue = range.upperBound
        valueStepper.increment = 1
        valueStepper.integerValue = value
        valueField?.stringValue = "\(value)"
        detailField?.stringValue = detail
    }

    @objc private func cancelTapped() {
        dismiss()
    }

    @objc private func beginTapped() {
        let mode = selectedMode
        let begin = onBegin
        dismiss()
        begin?(mode)
    }
}

// MARK: - 连拍拍摄状态条

/// 拍摄中始终可见：状态、模式、计数、暂停和结束动作保持在一条线上。
@MainActor
final class BurstLiveBarController {
    static let shared = BurstLiveBarController()

    private var panel: NSWindow?
    private var statusField: NSTextField?
    private var detailField: NSTextField?
    private var countField: NSTextField?
    private var pauseButton: NSButton?
    private var timer: Timer?
    private var keyMonitor: Any?
    private var onStop: (() -> Void)?
    private var mode: BurstMode = .burst
    private var auditAllowsInteraction = false
    private var auditPaused = false
    private var isMoreMenuOpen = false

    private init() {}

    func show(
        mode: BurstMode,
        on screen: NSScreen? = nil,
        auditAllowsInteraction: Bool = false,
        onStop: @escaping () -> Void
    ) {
        dismiss()
        self.onStop = onStop
        self.mode = mode
        self.auditAllowsInteraction = auditAllowsInteraction
        auditPaused = false

        let panelSize = NSSize(width: 520, height: 60)
        let (panel, isInteractiveAudit) = makeBurstPanel(
            size: panelSize,
            auditTitle: "Rune 连拍拍摄中"
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = isInteractiveAudit
            ? .normal
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSView(frame: NSRect(origin: .zero, size: panelSize))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.96).cgColor
        background.layer?.cornerRadius = 15
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        panel.contentView = background

        let dot = NSView(frame: NSRect(x: 18, y: 26, width: 9, height: 9))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 4.5
        background.addSubview(dot)

        let status = NSTextField(labelWithString: mode.liveTitle)
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = .white
        status.frame = NSRect(x: 36, y: 32, width: 126, height: 17)
        background.addSubview(status)
        statusField = status

        let modeDetail = NSTextField(labelWithString: mode.liveDetail)
        modeDetail.font = .systemFont(ofSize: 10)
        modeDetail.textColor = NSColor.white.withAlphaComponent(0.62)
        modeDetail.frame = NSRect(x: 36, y: 13, width: 152, height: 15)
        background.addSubview(modeDetail)
        detailField = modeDetail

        let count = NSTextField(labelWithString: "0 张")
        count.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        count.textColor = .white
        count.alignment = .right
        count.frame = NSRect(x: 178, y: 18, width: 104, height: 25)
        count.setAccessibilityLabel("已拍 0 张")
        background.addSubview(count)
        countField = count

        let pause = makePanelButton(
            title: "暂停",
            frame: NSRect(x: 300, y: 13, width: 70, height: 34),
            accent: false,
            target: self,
            action: #selector(pauseTapped)
        )
        pause.setAccessibilityLabel("暂停连拍")
        background.addSubview(pause)
        pauseButton = pause

        let stop = makePanelButton(
            title: "结束",
            frame: NSRect(x: 378, y: 13, width: 76, height: 34),
            accent: true,
            target: self,
            action: #selector(stopTapped)
        )
        stop.setAccessibilityLabel("结束连拍并挑选结果")
        background.addSubview(stop)

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多连拍操作") ?? NSImage(),
            target: self,
            action: #selector(moreTapped(_:))
        )
        more.frame = NSRect(x: 466, y: 17, width: 36, height: 28)
        more.isBordered = false
        more.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        more.setAccessibilityLabel("更多连拍操作")
        more.toolTip = "更多连拍操作"
        background.addSubview(more)

        refreshStatus()

        if let screenFrame = (screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screenFrame.midX - panelSize.width / 2, y: screenFrame.maxY - panelSize.height - 14))
        }
        panel.orderFrontRegardless()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-burst-live")
            || ProcessInfo.processInfo.arguments.contains("--audit-burst-interactive") {
            panel.makeKeyAndOrderFront(nil)
        }
        #endif
        self.panel = panel

        timer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshStatus()
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            switch event.keyCode {
            case 53: // Esc：结束并进入结果整理，不静默丢图
                guard self?.isMoreMenuOpen != true else { return event }
                self?.stopTapped()
                return nil
            case 49: // Space：暂停 / 继续
                self?.pauseTapped()
                return nil
            default:
                return event
            }
        }
    }

    private func refreshStatus() {
        let controller = BurstCaptureController.shared
        let count = controller.capturedCount
        let paused = controller.isActive ? controller.isPaused : auditPaused
        statusField?.stringValue = paused ? "连拍已暂停" : mode.liveTitle
        detailField?.stringValue = paused ? "已拍画面安全保留" : mode.liveDetail
        countField?.stringValue = mode.progressText(count: count)
        countField?.setAccessibilityLabel("已拍 \(count) 张")
        if let pauseButton {
            setPanelButtonTitle(pauseButton, title: paused ? "继续" : "暂停", accent: false)
            pauseButton.setAccessibilityLabel(paused ? "继续连拍" : "暂停连拍")
        }
    }

    @objc private func pauseTapped() {
        if BurstCaptureController.shared.isActive {
            BurstCaptureController.shared.togglePause()
        } else if auditAllowsInteraction {
            auditPaused.toggle()
        }
        refreshStatus()
    }

    @objc private func moreTapped(_ sender: NSButton) {
        let menu = NSMenu()
        let discard = NSMenuItem(
            title: "放弃这组连拍…",
            action: #selector(discardTapped),
            keyEquivalent: ""
        )
        discard.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        discard.target = self
        menu.addItem(discard)
        isMoreMenuOpen = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        // `popUp` 会先结束菜单，再把同一个 Esc 事件交回本地监听器。
        // 延后一轮解除标记，避免“关菜单”被误判成“结束连拍”。
        DispatchQueue.main.async { [weak self] in
            self?.isMoreMenuOpen = false
        }
    }

    @objc private func discardTapped() {
        let count = BurstCaptureController.shared.capturedCount
        let alert = NSAlert()
        alert.messageText = "放弃这组连拍？"
        alert.informativeText = count > 0
            ? "已拍的 \(count) 张图片会移到废纸篓，之后仍可恢复。"
            : "连拍会立即结束，不保存任何图片。"
        alert.addButton(withTitle: "放弃并移到废纸篓")
        alert.addButton(withTitle: "继续拍摄")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        dismiss()
        BurstCaptureController.shared.discard()
    }

    @objc private func stopTapped() {
        let stop = onStop
        dismiss()
        stop?()
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        statusField = nil
        detailField = nil
        countField = nil
        pauseButton = nil
        onStop = nil
        auditAllowsInteraction = false
        auditPaused = false
        isMoreMenuOpen = false
    }
}

// MARK: - Helpers

@MainActor
private extension BurstMode {
    init(segmentIndex: Int) {
        switch segmentIndex {
        case 1: self = .fixedCount
        case 2: self = .timelapse
        default: self = .burst
        }
    }

    var segmentIndex: Int {
        switch self {
        case .burst: 0
        case .fixedCount: 1
        case .timelapse: 2
        }
    }

    var liveTitle: String {
        switch self {
        case .burst: "连续拍摄中"
        case .fixedCount: "定数拍摄中"
        case .timelapse: "延时拍摄中"
        }
    }

    var liveDetail: String {
        let controller = BurstCaptureController.shared
        return switch self {
        case .burst: "\(controller.fps) 帧/秒"
        case .fixedCount: "目标 \(controller.fixedCount) 张"
        case .timelapse: "每 \(Int(controller.timelapseInterval)) 秒一张"
        }
    }

    func progressText(count: Int) -> String {
        let controller = BurstCaptureController.shared
        let limit = switch self {
        case .burst: controller.burstLimit
        case .fixedCount: controller.fixedCount
        case .timelapse: controller.timelapseLimit
        }
        return "\(count) / \(limit) 张"
    }
}

@MainActor
private func makePanelButton(
    title: String,
    frame: NSRect,
    accent: Bool,
    target: AnyObject,
    action: Selector
) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.frame = frame
    button.isBordered = false
    button.wantsLayer = true
    button.layer?.cornerRadius = 8
    button.layer?.backgroundColor = accent
        ? NSColor.systemRed.cgColor
        : NSColor.labelColor.withAlphaComponent(0.08).cgColor
    button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: accent ? NSColor.white : NSColor.labelColor,
        ]
    )
    return button
}

@MainActor
private func setPanelButtonTitle(_ button: NSButton, title: String, accent: Bool) {
    button.layer?.backgroundColor = accent
        ? NSColor.systemRed.cgColor
        : NSColor.white.withAlphaComponent(0.10).cgColor
    button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: accent ? NSColor.white : NSColor.white.withAlphaComponent(0.92),
        ]
    )
}

private final class BurstPanel: NSPanel {
    override var canBecomeKey: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--audit-burst-setup")
            || args.contains("--audit-burst-live")
            || args.contains("--audit-burst-interactive") {
            return true
        }
        #endif
        return false
    }
}

#if DEBUG
/// 只给自动交互验收使用的标准窗口；生产中的连拍仍使用不抢焦点的 BurstPanel。
private final class BurstAuditWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
#endif

@MainActor
private func makeBurstPanel(size: NSSize, auditTitle: String) -> (NSWindow, Bool) {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--audit-burst-interactive") {
        let auditWindow = BurstAuditWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        auditWindow.title = auditTitle
        return (auditWindow, true)
    }
    #endif

    let panel = BurstPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    return (panel, false)
}
