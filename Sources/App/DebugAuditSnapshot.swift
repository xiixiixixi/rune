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
