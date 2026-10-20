import AppKit

/// 截图主入口的模式（飞书同款：顶部一条模式条，截图 / 滚动截图 / 录屏 / 提取文字 一键互切）。
///
/// 飞书只有 `⌘⇧A` 一个入口，四种能力靠这条模式条切换；Rune 早期是八个独立热键，
/// 模式之间互不相通——想截长图得先取消当前截图再按另一个键。统一成一条模式条之后，
/// 框选途中也能改主意，松手即按新模式走。
enum CaptureMode: String, CaseIterable, Sendable {
    case region
    case scroll
    case recording
    case text

    var title: String {
        switch self {
        case .region: "截图"
        case .scroll: "滚动截图"
        case .recording: "录屏"
        case .text: "提取文字"
        }
    }

    var systemImage: String {
        switch self {
        case .region: "camera.viewfinder"
        case .scroll: "arrow.down.doc"
        case .recording: "record.circle"
        case .text: "text.viewfinder"
        }
    }
}

/// 选区顶部那条模式条（飞书同款）。
///
/// 画在选区浮层**自己的视图里**，而不是另开一个窗口：
/// - 另开面板在多屏与窗口层级上很难稳定压住全屏浮层；
/// - 浮层本身是全屏的，条画在浮层里，拖框起点落在条上时也不会把拖拽吃掉
///   （`mouseDown` 先做命中测试，落在条上就只切换模式，不起拖拽）。
struct CaptureModeBar {

    /// 条整体在所在屏视图坐标系里的矩形
    let rect: CGRect
    /// 当前选中的模式
    var current: CaptureMode

    private static let itemHeight: CGFloat = 30
    private static let itemSpacing: CGFloat = 2
    private static let iconSize: CGFloat = 13
    private static let itemPadding: CGFloat = 11
    private static let fontSize: CGFloat = 12
    private static let cornerRadius: CGFloat = 10

    private static var itemFont: NSFont {
        NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    }

    /// 每个模式项的宽度：图标 + 间距 + 文字 + 左右内边距
    private static func itemWidth(for mode: CaptureMode) -> CGFloat {
        let textWidth = (mode.title as NSString).size(withAttributes: [.font: itemFont]).width
        return iconSize + 5 + textWidth + itemPadding * 2
    }

    /// 模式条整体尺寸
    static func size() -> CGSize {
        let widths = CaptureMode.allCases.map(itemWidth(for:))
        let content = widths.reduce(0, +) + CGFloat(CaptureMode.allCases.count - 1) * itemSpacing
        return CGSize(width: content + itemPadding * 2, height: itemHeight + 10)
    }

    /// 模式条在指定屏上的位置：顶部居中。
    /// `visibleFrame` 已经扣掉菜单栏与 Dock，等于系统安全区，条不会压住它们。
    static func rect(on screen: NSScreen) -> CGRect {
        let size = size()
        let visible = screen.visibleFrame
        return CGRect(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 8,
            width: size.width,
            height: size.height
        )
    }

    /// 每个模式项的矩形（视图坐标系）
    func itemRects() -> [(mode: CaptureMode, rect: CGRect)] {
        let contentHeight = Self.itemHeight
        let top = rect.maxY - 5 - contentHeight
        var x = rect.minX + 5
        return CaptureMode.allCases.map { mode in
            let width = Self.itemWidth(for: mode)
            defer { x += width + Self.itemSpacing }
            return (mode, CGRect(x: x, y: top, width: width, height: contentHeight))
        }
    }

    /// 命中测试：点落在哪个模式上
    func mode(at point: CGPoint) -> CaptureMode? {
        itemRects().first { $0.rect.contains(point) }?.mode
    }

    /// 画这条模式条。视图是左下原点的常规坐标，与条的位置一致。
    func draw(in ctx: CGContext) {
        let background = NSBezierPath(
            roundedRect: rect,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        NSColor.black.withAlphaComponent(0.80).setFill()
        background.fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        background.lineWidth = 0.5
        background.stroke()

        for (mode, itemRect) in itemRects() {
            let isCurrent = mode == current
            if isCurrent {
                let pill = NSBezierPath(
                    roundedRect: itemRect,
                    xRadius: 7,
                    yRadius: 7
                )
                NSColor(calibratedRed: 0.23, green: 0.78, blue: 0.96, alpha: 1).setFill()
                pill.fill()
            }
            let foreground: NSColor = isCurrent
                ? NSColor.black.withAlphaComponent(0.86)
                : NSColor.white.withAlphaComponent(0.82)

            // 图标
            var iconRect = CGRect(
                x: itemRect.minX + Self.itemPadding,
                y: itemRect.midY - Self.iconSize / 2,
                width: Self.iconSize,
                height: Self.iconSize
            )
            if let symbol = NSImage(
                systemSymbolName: mode.systemImage,
                accessibilityDescription: mode.title
            ) {
                let configured = symbol.withSymbolConfiguration(
                    .init(pointSize: Self.iconSize, weight: .semibold)
                ) ?? symbol
                configured.isTemplate = true
                if let cgImage = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    ctx.saveGState()
                    ctx.setFillColor(foreground.cgColor)
                    // 模板图是黑色 alpha 通道，用它做遮罩填出当前色
                    ctx.clip(to: iconRect, mask: cgImage)
                    ctx.fill(iconRect)
                    ctx.restoreGState()
                }
            }

            // 文字
            let text = mode.title as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: Self.itemFont,
                .foregroundColor: foreground
            ]
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: iconRect.maxX + 5,
                y: itemRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: textRect, withAttributes: attributes)
        }
    }
}
