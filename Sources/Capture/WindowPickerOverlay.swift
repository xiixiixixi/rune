import AppKit

/// 窗口选择结果。
struct WindowSelection {
    let windowID: CGWindowID
    /// 窗口在全局点坐标的 frame（用于绘制高亮框）。
    let frame: CGRect
    let title: String?
}

/// 窗口选择器 overlay：鼠标悬停高亮光标下的窗口，点击选中返回该窗口 ID。
///
/// 设计参考 `RegionSelectionOverlay`（全屏无边框 overlay + 自绘视图 + continuation）。
/// 窗口列举用 `CGWindowListCopyWindowInfo`（系统 API，不需屏幕录制权限即可列举窗口元数据）；
/// 截图本身仍由 SCK 引擎负责（需权限）。
@MainActor
final class WindowPickerOverlay {
    private var overlayWindows: [NSWindow] = []
    private var continuation: CheckedContinuation<WindowSelection?, Never>?

    func pickWindow() async -> WindowSelection? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            showOverlays()
        }
    }

    private func showOverlays() {
        for screen in NSScreen.screens {
            let window = PickerWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenPrimary]

            let pickerView = PickerView(screen: screen) { [weak self] selection in
                self?.finish(with: selection)
            } onCancel: { [weak self] in
                self?.finish(with: nil)
            }

            window.contentView = pickerView
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(with selection: WindowSelection?) {
        closeOverlays()
        continuation?.resume(returning: selection)
        continuation = nil
    }

    private func closeOverlays() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }
}

// MARK: - Overlay Window

private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Picker View

private final class PickerView: NSView {
    private var hovered: WindowSelection?
    private var trackingArea: NSTrackingArea?
    private let screen: NSScreen
    private let onSelect: (WindowSelection) -> Void
    private let onCancel: () -> Void

    init(screen: NSScreen, onSelect: @escaping (WindowSelection) -> Void, onCancel: @escaping () -> Void) {
        self.screen = screen
        self.onSelect = onSelect
        self.onCancel = onCancel
        super.init(frame: screen.frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        // 全屏半透明遮罩（让用户知道在选窗口模式）
        NSColor.black.withAlphaComponent(0.2).setFill()
        bounds.fill()

        guard let hovered else { return }

        // 高亮框：把遮罩"挖空"，只对窗口外区域遮罩
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: localRect(for: hovered.frame)))
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()

        // 高亮边框
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: localRect(for: hovered.frame))
        border.lineWidth = 2
        border.stroke()

        // 窗口标题标签
        if let title = hovered.title, !title.isEmpty {
            let label = title as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: RuneFont.appKit(size: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attrs)
            let labelRect = CGRect(
                x: localRect(for: hovered.frame).minX,
                y: localRect(for: hovered.frame).minY - size.height - 8,
                width: size.width + 12,
                height: size.height + 4
            )
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attrs)
        }
    }

    /// 全局点 frame → 本视图局部坐标 frame（本视图 frame = screen.frame，原点对齐）。
    private func localRect(for globalFrame: CGRect) -> CGRect {
        CGRect(
            x: globalFrame.origin.x - screen.frame.origin.x,
            y: globalFrame.origin.y - screen.frame.origin.y,
            width: globalFrame.width,
            height: globalFrame.height
        )
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        // 转成全局点坐标
        let globalPoint = CGPoint(
            x: localPoint.x + screen.frame.origin.x,
            y: localPoint.y + screen.frame.origin.y
        )
        if let sel = WindowPickerOverlay.windowAt(point: globalPoint) {
            hovered = sel
        } else {
            hovered = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let hovered else {
            onCancel()
            return
        }
        onSelect(hovered)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onCancel()
        }
    }
}

// MARK: - 窗口命中检测（静态工具）

extension WindowPickerOverlay {
    /// 找到包含某全局点的最顶层可截图窗口（排除自身、桌面、菜单栏、Dock 等系统层）。
    /// 用 CGWindowListCopyWindowInfo（不需屏幕录制权限）。
    ///
    /// 关键过滤：只选 `kCGWindowLayer == 0` 的正常应用窗口。
    /// Dock/菜单栏/壁纸/控制中心等系统 UI 在更高 layer（≥20），选到它们会截到黑屏或无意义内容。
    static func windowAt(point: CGPoint) -> WindowSelection? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }

        for info in windowInfo {
            // 只看 layer 0 的正常应用窗口（排除 Dock/菜单栏/壁纸等系统层）
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            // 排除无 bounds 或过小的窗口
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  w > 50, h > 50 else { continue }

            // CGWindowList 的坐标是左上原点，转成 AppKit 左下原点的全局坐标
            let appKitRect = CGRect(
                x: x,
                y: primaryHeight - (y + h),
                width: w,
                height: h
            )
            guard appKitRect.contains(point) else { continue }

            // 排除自身进程
            if let ownerPID = info[kCGWindowOwnerPID as String] as? Int32,
               ownerPID == myPID {
                continue
            }

            let windowID = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            guard windowID != 0 else { continue }

            let title = info[kCGWindowName as String] as? String
            return WindowSelection(windowID: windowID, frame: appKitRect, title: title)
        }
        return nil
    }
}
