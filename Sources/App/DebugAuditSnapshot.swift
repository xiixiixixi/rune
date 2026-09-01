#if DEBUG
import AppKit
@preconcurrency import ScreenCaptureKit

/// 锁屏或无法操作桌面时，也能把调试验收窗口本身渲染成 PNG。
@MainActor
enum DebugAuditSnapshot {
    static let directory = URL(fileURLWithPath: "/tmp/rune-ui-audit", isDirectory: true)

    static func captureAfter(_ filename: String, delay: TimeInterval = 0.9) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            captureFrontmost(filename)
        }
    }

    static func captureWindowLayoutAfter(_ filename: String, delay: TimeInterval = 0.9) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let lines = NSApp.windows
                .filter(\.isVisible)
                .sorted { $0.level.rawValue < $1.level.rawValue }
                .map { window in
                    "\(String(describing: type(of: window))) frame=\(window.frame) level=\(window.level.rawValue)"
                }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? lines.joined(separator: "\n").write(
                to: directory.appendingPathComponent(filename),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// 截图确认模式同时有全屏画布和悬浮工具栏；单独抓最小窗口验证工具栏本身。
    static func captureSmallestAfter(_ filename: String, delay: TimeInterval = 0.9) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let candidates = visibleCandidates()
            guard let window = candidates.min(by: {
                $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
            }) else { return }
            capture(window, filename: filename)
        }
    }

    static func captureClosestToSizeAfter(
        _ filename: String,
        size: CGSize,
        delay: TimeInterval = 0.9
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = visibleCandidates().min(by: { lhs, rhs in
                let lhsDistance = abs(lhs.frame.width - size.width) + abs(lhs.frame.height - size.height)
                let rhsDistance = abs(rhs.frame.width - size.width) + abs(rhs.frame.height - size.height)
                return lhsDistance < rhsDistance
            }) else { return }
            capture(window, filename: filename)
        }
    }

    /// 把 Rune 同时显示的多个调试悬浮窗按真实屏幕坐标合成，验证跨窗口的选区、预览和控制布局。
    static func captureWindowsCompositeAfter(
        _ filename: String,
        on screen: NSScreen?,
        background: NSImage? = nil,
        delay: TimeInterval = 0.9
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let screen else { return }
            let screenBounds = CGRect(origin: .zero, size: screen.frame.size)
            let backingScale = max(screen.backingScaleFactor, 1)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: max(Int(screenBounds.width * backingScale), 1),
                pixelsHigh: max(Int(screenBounds.height * backingScale), 1),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }

            bitmap.size = screenBounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            screenBounds.fill()
            background?.draw(in: screenBounds)

            let windows = visibleCandidates()
                .filter { !$0.frame.intersection(screen.frame).isNull }
                .sorted { lhs, rhs in
                    if lhs.level.rawValue == rhs.level.rawValue {
                        return lhs.windowNumber < rhs.windowNumber
                    }
                    return lhs.level.rawValue < rhs.level.rawValue
                }
            for window in windows {
                guard let view = window.contentView,
                      let data = captureCachedView(view),
                      let image = NSImage(data: data) else { continue }
                let destination = CGRect(
                    x: window.frame.minX - screen.frame.minX,
                    y: window.frame.minY - screen.frame.minY,
                    width: window.frame.width,
                    height: window.frame.height
                )
                image.draw(in: destination)
            }
            NSGraphicsContext.restoreGraphicsState()

            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            write(data, filename: filename)
        }
    }

    private static func captureFrontmost(_ filename: String) {
        let candidates = visibleCandidates()
        guard let window = candidates.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }) else { return }

        capture(window, filename: filename)
    }

    private static func visibleCandidates() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible
                && window.contentView != nil
                && window.frame.width >= 80
                && window.frame.height >= 36
        }
    }

    private static func capture(_ window: NSWindow, filename: String) {
        Task { @MainActor in
            // 低矮无边框悬浮条在窗口服务器中只有透明材质，没有可读前景；视图缓存更准确。
            if window.frame.height <= 140,
               let view = window.contentView,
               let data = captureCachedView(view) {
                write(data, filename: filename)
                return
            }

            if let data = await captureWindowServerImage(window) {
                write(data, filename: filename)
                return
            }

            guard let view = window.contentView,
                  let data = captureCachedView(view) else { return }
            write(data, filename: filename)
        }
    }

    /// 原生工具栏、Material 和多栏窗口不会完整进入 cacheDisplay；调试验收优先抓窗口服务器里的真窗口。
    private static func captureWindowServerImage(_ window: NSWindow) async -> Data? {
        guard CGPreflightScreenCaptureAccess() else { return nil }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let sharedWindow = content.windows.first(where: {
                $0.windowID == CGWindowID(window.windowNumber)
            }) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: sharedWindow)
            let configuration = SCStreamConfiguration()
            let scale = max(window.backingScaleFactor, 1)
            configuration.width = max(Int(window.frame.width * scale), 1)
            configuration.height = max(Int(window.frame.height * scale), 1)
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return NSBitmapImageRep(cgImage: image).representation(
                using: .png,
                properties: [:]
            )
        } catch {
            print("窗口验收截图失败，回退视图缓存：\(error)")
            return nil
        }
    }

    private static func captureCachedView(_ view: NSView) -> Data? {

        let bounds = view.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }

        view.cacheDisplay(in: bounds, to: bitmap)

        // 透明玻璃条在 PNG 查看器里会落到黑底，导致主文字也像“消失”。
        // 调试证据统一合成到系统窗口底色，产品窗口本身仍保持透明。
        guard let flattened = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: flattened) else {
            return bitmap.representation(using: .png, properties: [:])
        }

        flattened.size = bitmap.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: bitmap.size).fill()
        bitmap.draw(in: NSRect(origin: .zero, size: bitmap.size))
        NSGraphicsContext.restoreGraphicsState()

        return flattened.representation(using: .png, properties: [:])
    }

    private static func write(_ data: Data, filename: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}
#endif
