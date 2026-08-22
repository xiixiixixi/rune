#if DEBUG
import AppKit

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

    private static func captureFrontmost(_ filename: String) {
        let candidates = NSApp.windows.filter { window in
            window.isVisible
                && window.contentView != nil
                && window.frame.width >= 80
                && window.frame.height >= 36
        }
        guard let window = candidates.max(by: { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }), let view = window.contentView else { return }

        let bounds = view.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }

        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(filename), options: .atomic)
    }
}
#endif
