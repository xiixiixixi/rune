import AppKit
import CaptureKit
import CoreGraphics
import ScreenCaptureKit

/// 基于 ScreenCaptureKit 的静态截图引擎（单帧，非持续推流）。
///
/// 设计依据：M1 设计文档 §3.1 —— 优先走 `SCScreenshotManager`（macOS 14+ 单帧 API），
/// 比录屏用的 `SCStream`（持续推流）轻得多。
///
/// 类型设计说明：
/// - `CaptureEngine` 协议要求 `Sendable`，本类型因此用 `final class` + `@unchecked Sendable`。
///   当前实现无可变状态（预热缓存见下），因此线程安全。
/// - 预热缓存：本轮（M1 第⑤步最小切片）暂不缓存 `SCShareableContent`，每次截图现取。
///   原因是 `SCShareableContent` 不符合 `Sendable`，缓存它需引入 actor 或加锁；
///   Swift 6 禁止在 async 上下文用 `NSLock`，而性能优化的预热逻辑属于下一轮范围，
///   本轮先把功能通路跑通。`prewarm()` 走协议默认空实现。
/// - 本 target 单独存在，是为了让纯逻辑的 `CaptureKit` target 可在无屏幕权限/无 SCK
///   的环境下用 `swift test` 独立验证。
public final class SCKStillCaptureBackend: StillCaptureBackend, @unchecked Sendable {
    /// 排除的应用 bundleID 集合（默认排除本应用自身，避免把悬浮 UI 录进去）。
    private let excludingBundleIDs: Set<String>

    /// 屏幕清单缓存：SCShareableContent 查询要 0.5–1.5s（截图卡顿的元凶），
    /// 用 actor 存 5 秒内的快照；prewarm 提前填好，capture 直接命中。
    private let store = ContentStore()

    public init(excludingBundleIDs: Set<String> = []) {
        var ids = excludingBundleIDs
        if let myBundleID = Bundle.main.bundleIdentifier {
            ids.insert(myBundleID)
        }
        self.excludingBundleIDs = ids
    }

    // MARK: - CaptureEngine

    /// 预热：填屏幕清单缓存 + 用 1×1 像素不可见小图焐热采集管线。
    /// 在选区 overlay 弹出时调用，拖框期间就完成，松手即拍。
    public func prewarm() async throws {
        let content = try await store.fetch(force: true).content
        guard let display = content.displays.first else { return }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter {
                excludingBundleIDs.contains($0.bundleIdentifier)
            },
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.width = 1
        config.height = 1
        config.showsCursor = false
        _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    public func capture(_ target: CaptureTarget) async throws -> CapturedFrame {
        let content = try await contentFor(target)

        // 跨显示器选区：分别截取每块屏幕上的交集，再按全局位置拼成一张图。
        // 单块显示器路径仍走下面的轻量单帧逻辑。
        if case .region(let globalRect) = target {
            let intersecting = content.displays.filter { !$0.frame.intersection(globalRect).isNull }
            if intersecting.count > 1 {
                return try await captureCrossDisplayRegion(globalRect, displays: intersecting, content: content)
            }
        }

        let (filter, displayID) = try buildFilter(for: target, in: content)
        let config = SCStreamConfiguration()
        configure(config: config, filter: filter, target: target, content: content)

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw CaptureError.captureFailed
        }

        let scaleFactor: CGFloat
        if filter.contentRect.width > 0 {
            scaleFactor = CGFloat(image.width) / filter.contentRect.width
        } else {
            scaleFactor = await Self.mainScreenScaleFactor()
        }
        return CapturedFrame(
            image: image,
            scaleFactor: scaleFactor,
            displayID: displayID
        )
    }

    private func captureCrossDisplayRegion(
        _ globalRect: CGRect,
        displays: [SCDisplay],
        content: SCShareableContent
    ) async throws -> CapturedFrame {
        let excludedApps = content.applications.filter {
            excludingBundleIDs.contains($0.bundleIdentifier)
        }
        var pieces: [(rect: CGRect, image: CGImage, scale: CGFloat)] = []

        for display in displays {
            let intersection = globalRect.intersection(display.frame)
            guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { continue }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            let scale = CGFloat(filter.pointPixelScale)
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(
                x: intersection.minX - display.frame.minX,
                y: intersection.minY - display.frame.minY,
                width: intersection.width,
                height: intersection.height
            )
            config.width = Int(intersection.width * scale)
            config.height = Int(intersection.height * scale)
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            pieces.append((intersection, image, scale))
        }

        guard !pieces.isEmpty else { throw CaptureError.captureFailed }
        let outputScale = pieces.map(\.scale).max() ?? 1
        let width = max(1, Int(globalRect.width * outputScale))
        let height = max(1, Int(globalRect.height * outputScale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { throw CaptureError.captureFailed }

        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        for piece in pieces {
            let destination = CGRect(
                x: (piece.rect.minX - globalRect.minX) * outputScale,
                y: (piece.rect.minY - globalRect.minY) * outputScale,
                width: piece.rect.width * outputScale,
                height: piece.rect.height * outputScale
            )
            context.draw(piece.image, in: destination)
        }
        guard let image = context.makeImage() else { throw CaptureError.captureFailed }
        return CapturedFrame(image: image, scaleFactor: outputScale, displayID: nil)
    }

    // MARK: - 私有：内容获取 / 过滤器 / 配置

    /// 取屏幕清单：命中缓存直接用；窗口目标在缓存里找不到对应窗口时
    /// （窗口刚打开等），强制刷新一次再试。
    private func contentFor(_ target: CaptureTarget) async throws -> SCShareableContent {
        let cached = try await store.fetch().content
        if case .window(let windowID) = target,
           !cached.windows.contains(where: { $0.windowID == windowID }) {
            return try await store.fetch(force: true).content
        }
        return cached
    }

    private func fetchShareableContent() async throws -> SCShareableContent {
        try await store.fetch().content
    }

    private func buildFilter(
        for target: CaptureTarget,
        in content: SCShareableContent
    ) throws -> (SCContentFilter, CGDirectDisplayID?) {
        let excludedApps = content.applications.filter {
            excludingBundleIDs.contains($0.bundleIdentifier)
        }

        switch target {
        case .fullscreen:
            guard let display = content.displays.first else {
                throw CaptureError.captureFailed
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            return (filter, display.displayID)

        case .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.captureFailed
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            return (filter, displayID)

        case .region(let globalRect):
            // 选区是全局 AppKit 点坐标。用选区中心点判断所属显示器（修正
            // ScreenRecordingManager 写死主屏的 bug）。
            let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
            guard let display = displayContaining(point: center, in: content.displays) else {
                throw CaptureError.captureFailed
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApps,
                exceptingWindows: []
            )
            return (filter, display.displayID)

        case .window(let windowID):
            // 从可共享内容的窗口列表里按 windowID 匹配到 SCWindow。
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CaptureError.captureFailed
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            return (filter, nil)
        }
    }

    /// 返回包含某点的显示器。display.frame 是全局点坐标（AppKit 左下原点）。
    private func displayContaining(
        point: CGPoint,
        in displays: [SCDisplay]
    ) -> SCDisplay? {
        displays.first { $0.frame.contains(point) }
    }

    /// 配置 SCStreamConfiguration。
    /// - 全屏/显示器/窗口：输出尺寸 = contentRect × scale，不设 sourceRect。
    /// - 区域：输出尺寸 = sourceRect × scale，并设 sourceRect 裁剪到选区。
    private func configure(
        config: SCStreamConfiguration,
        filter: SCContentFilter,
        target: CaptureTarget,
        content: SCShareableContent
    ) {
        let scale = CGFloat(filter.pointPixelScale)

        switch target {
        case .region(let globalRect):
            // sourceRect 在"所选 display 的逻辑坐标系"内（原点对该 display 的 contentRect）。
            // X/Y 都要减去 display origin（修正 ScreenRecordingManager 漏 Y 轴换算的 bug）。
            guard let display = displayContaining(
                point: CGPoint(x: globalRect.midX, y: globalRect.midY),
                in: content.displays
            ) else {
                // 找不到显示器时回退到全 contentRect（不应发生，buildFilter 已抛错）
                config.width = Int(filter.contentRect.width * scale)
                config.height = Int(filter.contentRect.height * scale)
                break
            }
            // 选区限制在该 display 内（clamp 防越界）
            let clamped = globalRect.intersection(display.frame)
            // 换算到 display 局部坐标（display.frame.origin 为该屏在全局的原点）
            let localRect = CGRect(
                x: clamped.origin.x - display.frame.origin.x,
                y: clamped.origin.y - display.frame.origin.y,
                width: clamped.width,
                height: clamped.height
            )
            config.sourceRect = localRect
            config.width = Int(clamped.width * scale)
            config.height = Int(clamped.height * scale)

        default:
            // 全屏 / 显示器 / 窗口：用 contentRect 整体
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
        }

        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
    }

    @MainActor
    private static func mainScreenScaleFactor() -> CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }
}

// MARK: - 屏幕清单缓存

/// SCShareableContent 不符合 Sendable，用 @unchecked Sendable 包一层存进 actor。
/// 它本身是不可变快照，跨隔离区只读是安全的。
private actor ContentStore {
    struct Snapshot: @unchecked Sendable {
        let content: SCShareableContent
    }

    private var snapshot: Snapshot?
    private var fetchedAt: Date = .distantPast
    /// 屏幕布局很少变；30 秒内直接复用快照（覆盖慢慢拖框的场景），过期自动重查
    private let ttl: TimeInterval = 30

    /// 返回值必须是 Sendable 包装（Swift 6 禁止 actor 直接返回非 Sendable），
    /// 调用方自行 .content 拆箱。
    func fetch(force: Bool = false) async throws -> Snapshot {
        if !force, let snapshot, Date().timeIntervalSince(fetchedAt) < ttl {
            return snapshot
        }
        let fresh = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let newSnapshot = Snapshot(content: fresh)
        self.snapshot = newSnapshot
        self.fetchedAt = Date()
        return newSnapshot
    }
}
