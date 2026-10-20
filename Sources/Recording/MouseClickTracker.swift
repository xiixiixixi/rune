import AppKit
import CoreGraphics
import Foundation

/// 记录鼠标点击的位置，供录屏画面的「点击高亮」使用。
///
/// 为什么自己实现而不是用系统自带的开关：
/// ScreenCaptureKit 的 `showMouseClicks` 会在点击处画一个圈，但实测
/// （macOS 27，真实录制 + 真实点击事件）画面里并没有出现这个圈，
/// 依赖它等于把功能押在一个不确定的行为上。
/// 自己监听点击、自己画圈，行为可控、也能单独验证。
///
/// 坐标：统一用 **CG 全局坐标**（左上角为原点、y 向下），
/// 和 ScreenCaptureKit 的显示器坐标系一致，映射时少一次翻转。
final class MouseClickTracker: @unchecked Sendable {

    struct Mark: Sendable {
        /// CG 全局坐标（左上原点）
        let point: CGPoint
        /// 事件发生时刻（与 CACurrentMediaTime 同一时间基准）
        let timestamp: CFTimeInterval
    }

    private let lock = NSLock()
    private var marks: [Mark] = []
    private var monitor: Any?

    /// 点击高亮圈的存活时长（秒）
    static let highlightDuration: CFTimeInterval = 0.45

    func start() {
        stop()
        let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let point = Self.globalPoint(of: event) else { return }
            self?.add(point: point)
        }
        lock.lock()
        self.monitor = monitor
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let current = monitor
        monitor = nil
        marks.removeAll()
        lock.unlock()
        if let current {
            NSEvent.removeMonitor(current)
        }
    }

    func add(point: CGPoint) {
        lock.lock()
        marks.append(Mark(point: point, timestamp: CACurrentMediaTime()))
        // 只留最近两秒内的，够用也不会无限增长。
        let cutoff = CACurrentMediaTime() - 2
        marks.removeAll { $0.timestamp < cutoff }
        lock.unlock()
    }

    /// 取最近 `duration` 秒内的点击。
    func recentMarks(within duration: CFTimeInterval = MouseClickTracker.highlightDuration) -> [Mark] {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        return marks.filter { now - $0.timestamp <= duration }
    }

    /// 把 NSEvent 的位置换算成 CG 全局坐标（左上原点）。
    private static func globalPoint(of event: NSEvent) -> CGPoint? {
        if let cgEvent = event.cgEvent {
            return cgEvent.location
        }
        // 兜底：AppKit 是左下原点，转成 CG 的左上原点。
        let appKit = event.window.map { window in
            window.convertPoint(toScreen: event.locationInWindow)
        } ?? NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(appKit) })
                ?? NSScreen.main else { return nil }
        let cgY = (screen.frame.origin.y + screen.frame.height) - appKit.y
        return CGPoint(x: appKit.x, y: cgY)
    }
}

/// 全局屏幕坐标 → 录像像素坐标的映射。
///
/// 录像覆盖的是某块显示器（或其中一块区域），录像画面是这块区域的像素化结果。
/// 点击事件给的是全局坐标，两者之间要按捕获区域与视频尺寸换算。
struct CaptureFrameMapping: Sendable {
    /// 捕获区域在 CG 全局坐标里的左上角
    let regionOrigin: CGPoint
    /// 捕获区域尺寸（点）
    let regionSize: CGSize
    /// 视频画面尺寸（像素）
    let pixelSize: CGSize

    /// 全局坐标 → 像素坐标。落在捕获区域外返回 nil。
    func pixel(for globalPoint: CGPoint) -> CGPoint? {
        guard regionSize.width > 0, regionSize.height > 0 else { return nil }
        let scaleX = pixelSize.width / regionSize.width
        let scaleY = pixelSize.height / regionSize.height
        let x = (globalPoint.x - regionOrigin.x) * scaleX
        let y = (globalPoint.y - regionOrigin.y) * scaleY
        guard x >= 0, y >= 0, x < pixelSize.width, y < pixelSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }
}
