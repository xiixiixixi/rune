import AppKit
import SwiftUI

enum AnnotationResizeHandle: CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case start
    case control
    case end

    static var boxCases: [AnnotationResizeHandle] {
        [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }

    static var endpointCases: [AnnotationResizeHandle] {
        [.start, .end]
    }

    static var arrowCases: [AnnotationResizeHandle] {
        [.control, .start, .end]
    }

    static func handles(for tool: AnnotationTool) -> [AnnotationResizeHandle] {
        tool == .arrow ? arrowCases : endpointCases
    }

    func corner(in rect: CGRect) -> CGPoint? {
        switch self {
        case .topLeft:
            CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight:
            CGPoint(x: rect.maxX, y: rect.maxY)
        case .start, .control, .end:
            nil
        }
    }

    func oppositeCorner(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:
            CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft:
            CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight:
            CGPoint(x: rect.minX, y: rect.minY)
        case .start, .control, .end:
            .zero
        }
    }

    func constrainedPoint(_ point: CGPoint, from anchor: CGPoint, minimumSize: CGFloat) -> CGPoint {
        switch self {
        case .topLeft:
            CGPoint(x: min(point.x, anchor.x - minimumSize), y: min(point.y, anchor.y - minimumSize))
        case .topRight:
            CGPoint(x: max(point.x, anchor.x + minimumSize), y: min(point.y, anchor.y - minimumSize))
        case .bottomLeft:
            CGPoint(x: min(point.x, anchor.x - minimumSize), y: max(point.y, anchor.y + minimumSize))
        case .bottomRight:
            CGPoint(x: max(point.x, anchor.x + minimumSize), y: max(point.y, anchor.y + minimumSize))
        case .start, .control, .end:
            point
        }
    }

    func point(in item: AnnotationItem) -> CGPoint? {
        switch self {
        case .start:
            item.points.first
        case .control:
            item.arrowCurveHandle
        case .end:
            item.points.last
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            nil
        }
    }
}


enum AnnotationTextMetrics {
    static let minimumFontSize: CGFloat = 9
    static let defaultNormalizedLineHeight: CGFloat = 0.06
    static let defaultFontName: String = "SF Pro"
    static let fontScale: CGFloat = 0.72

    static func defaultCaptureFontSize(imagePixelWidth: CGFloat) -> CGFloat {
        guard imagePixelWidth.isFinite else { return 18 }
        return min(max((imagePixelWidth * 0.015).rounded(), 18), 44)
    }

    static func normalizedLineHeight(fontPixelSize: CGFloat, imagePixelHeight: CGFloat) -> CGFloat {
        guard fontPixelSize.isFinite, fontPixelSize > 0,
              imagePixelHeight.isFinite, imagePixelHeight > 0 else {
            return defaultNormalizedLineHeight
        }
        return fontPixelSize / (imagePixelHeight * fontScale)
    }

    static var textShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 1.4
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        return shadow
    }

    static func viewFontSize(lineHeight: CGFloat, imageFrameHeight: CGFloat) -> CGFloat {
        max(lineHeight * imageFrameHeight * fontScale, minimumFontSize)
    }

    static func renderedFontSize(lineHeight: CGFloat, imagePixelHeight: CGFloat) -> CGFloat {
        max(lineHeight * imagePixelHeight * fontScale, minimumFontSize)
    }

    static func lineCount(for text: String) -> Int {
        let lines = text.components(separatedBy: .newlines)
        return max(lines.count, 1)
    }

    static func minimumNormalizedWidth(lineHeight: CGFloat, imageSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 0.02 }
        let fontSize = renderedFontSize(lineHeight: lineHeight, imagePixelHeight: imageSize.height)
        return max(0.02, (fontSize * 0.5 + 4) / imageSize.width)
    }

    static func resolvedFont(name: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var descriptor: NSFontDescriptor
        if let family = NSFontManager.shared.availableMembers(ofFontFamily: name), !family.isEmpty {
            descriptor = NSFontDescriptor(fontAttributes: [.family: name]).withSize(size)
        } else {
            descriptor = NSFont.systemFont(ofSize: size).fontDescriptor
        }

        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        if !traits.isEmpty {
            descriptor = descriptor.withSymbolicTraits(traits)
        }

        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size)
    }
}

enum AnnotationNumberedCircleMetrics {
    static let normalizedDiameter: CGFloat = 0.039

    static func defaultRect(
        centeredAt point: CGPoint,
        imageSize: CGSize,
        within allowedBounds: CGRect
    ) -> CGRect {
        let height = normalizedDiameter
        let width = imageSize.width > 0
            ? height * max(imageSize.height, 1) / imageSize.width
            : height
        let maxX = max(allowedBounds.minX, allowedBounds.maxX - width)
        let maxY = max(allowedBounds.minY, allowedBounds.maxY - height)

        return CGRect(
            x: min(max(point.x - width / 2, allowedBounds.minX), maxX),
            y: min(max(point.y - height / 2, allowedBounds.minY), maxY),
            width: width,
            height: height
        )
    }

    static func fontSize(for diameter: CGFloat, text: String) -> CGFloat {
        let digitCount = max(text.count, 1)
        let scale: CGFloat
        if digitCount <= 2 {
            scale = 0.54
        } else if digitCount == 3 {
            scale = 0.44
        } else {
            scale = 0.34
        }

        return max(8, diameter * scale)
    }

    static func outlineWidth(for diameter: CGFloat) -> CGFloat {
        max(1, diameter * 0.055)
    }
}

enum AnnotationFilledRectangleMetrics {
    static func cornerRadius(for rect: CGRect) -> CGFloat {
        min(12, max(3, min(rect.width, rect.height) * 0.08))
    }
}


/// 荧光笔高亮（飞书同款）：半透明色块以 multiply 混合压在画面上，
/// 底下文字仍可读。透明度沿用飞书 draw_highlight_opacity 的默认档位。
enum AnnotationHighlightMetrics {
    static let opacity: CGFloat = 0.45

    static func highlightColor(for swatch: AnnotationSwatch) -> NSColor {
        swatch.nsColor.withAlphaComponent(opacity)
    }
}


/// 指向性标注气泡（飞书同款「标签」）：
/// 点击处落一个红点锚点，右侧跟一个深色圆角气泡，气泡左边伸出三角尖指向锚点，
/// 气泡里写说明文字。用来指着截图里的某处说"这里有问题"。
enum AnnotationTagMetrics {
    /// 锚点红点直径（按图高比例）
    static let normalizedDotDiameter: CGFloat = 0.026
    /// 气泡宽度（按图宽比例）
    static let normalizedWidth: CGFloat = 0.17
    /// 气泡高度（按图高比例）
    static let normalizedHeight: CGFloat = 0.095
    /// 红点与气泡之间留出的缝隙（按图高比例），三角尖落在这段里
    static let normalizedGap: CGFloat = 0.028

    static let dotColor = NSColor(srgbRed: 0.94, green: 0.21, blue: 0.20, alpha: 1)
    static let bubbleColor = NSColor(srgbRed: 0.20, green: 0.21, blue: 0.23, alpha: 1)
    static let textColor = NSColor.white

    /// 气泡默认落在锚点右侧；右侧放不下时翻到左侧。
    static func defaultRect(anchor: CGPoint, within allowedBounds: CGRect) -> CGRect {
        let width = normalizedWidth
        let height = normalizedHeight
        let gap = normalizedGap
        let rightX = anchor.x + gap
        let leftX = anchor.x - gap - width
        let x: CGFloat
        if rightX + width <= allowedBounds.maxX {
            x = rightX
        } else if leftX >= allowedBounds.minX {
            x = leftX
        } else {
            x = min(max(anchor.x - width / 2, allowedBounds.minX), max(allowedBounds.minX, allowedBounds.maxX - width))
        }
        let y = min(
            max(anchor.y - height / 2, allowedBounds.minY),
            max(allowedBounds.minY, allowedBounds.maxY - height)
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 气泡内文字的行高（按图高比例）：气泡高度的 42%，
    /// 让 1–2 行文字在气泡里居中不溢出。
    static func normalizedLineHeight() -> CGFloat {
        normalizedHeight * 0.42
    }

    /// 三角尖：从气泡靠锚点的一侧中点，收到锚点。
    static func tailPath(
        bubble: CGRect,
        anchor: CGPoint,
        tailLength: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let towardsAnchor = anchor.x < bubble.midX
        let baseX = towardsAnchor ? bubble.minX : bubble.maxX
        let tipX = towardsAnchor ? baseX - tailLength : baseX + tailLength
        let halfHeight = bubble.height * 0.22
        path.move(to: CGPoint(x: baseX, y: bubble.midY - halfHeight))
        path.addLine(to: CGPoint(x: tipX, y: anchor.y))
        path.addLine(to: CGPoint(x: baseX, y: bubble.midY + halfHeight))
        path.closeSubpath()
        return path
    }
}


/// 全图斜排水印（飞书同款）：一条可编辑的文字平铺在整张截图上。
enum AnnotationWatermarkMetrics {
    /// 水印文字的倾斜角（弧度）。渲染时在归一化的 Y-down 坐标系里按此值
    /// 顺时针旋转，文字呈现左上→右下的「\」方向。
    static let tiltAngle: CGFloat = CGFloat.pi / 6
    /// 与飞书 draw_watermark_opacity 对齐的默认不透明度
    static let opacity: CGFloat = 0.34
    /// 水印字号约占图高的比例（textLineHeight 由它换算）
    static let normalizedFontSize: CGFloat = 0.045
    /// 相邻水印之间的基准间距 = 字号 × 这两个系数（横/纵）
    static let spacingScaleX: CGFloat = 4.2
    static let spacingScaleY: CGFloat = 3.1

    static func defaultText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = formatter.string(from: Date())
        let name = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Rune · \(stamp)" : "\(name) · \(stamp)"
    }

    static func normalizedLineHeight(imagePixelHeight: CGFloat) -> CGFloat {
        // renderedFontSize = lineHeight × imageHeight × fontScale ≈ 图高 × 4.5%
        normalizedFontSize / AnnotationTextMetrics.fontScale
    }
}


struct AnnotationArrowGeometry {
    let tip: CGPoint
    let shaftControl: CGPoint
    let firstWing: CGPoint
    let secondWing: CGPoint

    init?(start: CGPoint, control: CGPoint, end: CGPoint, lineWidth: CGFloat) {
        let curveLength = Self.approximateCurveLength(start: start, control: control, end: end)
        guard curveLength > 0.5 else { return nil }

        let tangent = Self.tangent(start: start, control: control, end: end)
        let tangentLength = hypot(tangent.x, tangent.y)
        guard tangentLength > 0.5 else { return nil }

        let direction = CGPoint(x: tangent.x / tangentLength, y: tangent.y / tangentLength)
        let backwardDirection = CGPoint(x: -direction.x, y: -direction.y)
        let headLength = min(max(13, lineWidth * 4.4), curveLength * 0.34)
        let headAngle = CGFloat.pi * 0.2
        let firstDirection = Self.rotate(backwardDirection, by: headAngle)
        let secondDirection = Self.rotate(backwardDirection, by: -headAngle)

        tip = end
        shaftControl = control
        firstWing = CGPoint(
            x: end.x + firstDirection.x * headLength,
            y: end.y + firstDirection.y * headLength
        )
        secondWing = CGPoint(
            x: end.x + secondDirection.x * headLength,
            y: end.y + secondDirection.y * headLength
        )
    }

    private static func approximateCurveLength(start: CGPoint, control: CGPoint, end: CGPoint) -> CGFloat {
        var length: CGFloat = 0
        var previous = start

        for step in 1...24 {
            let point = quadraticPoint(start: start, control: control, end: end, t: CGFloat(step) / 24)
            length += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }

        return length
    }

    private static func quadraticPoint(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let first = lerp(start, control, t)
        let second = lerp(control, end, t)
        return lerp(first, second, t)
    }

    private static func tangent(start: CGPoint, control: CGPoint, end: CGPoint) -> CGPoint {
        let tangent = CGPoint(
            x: 2 * (end.x - control.x),
            y: 2 * (end.y - control.y)
        )

        if hypot(tangent.x, tangent.y) > 0.5 {
            return tangent
        }

        return CGPoint(
            x: end.x - start.x,
            y: end.y - start.y
        )
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(angle) - point.y * sin(angle),
            y: point.x * sin(angle) + point.y * cos(angle)
        )
    }

    private static func lerp(_ lhs: CGPoint, _ rhs: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(
            x: lhs.x + (rhs.x - lhs.x) * t,
            y: lhs.y + (rhs.y - lhs.y) * t
        )
    }
}


struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var rect: CGRect
    var points: [CGPoint]
    var swatch: AnnotationSwatch
    var strokeWidth: CGFloat
    var redactionDensity: CGFloat
    var text: String
    var textLineHeight: CGFloat
    var fontName: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderline: Bool
    var textAlignment: NSTextAlignment

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        rect: CGRect,
        points: [CGPoint] = [],
        swatch: AnnotationSwatch,
        strokeWidth: CGFloat,
        redactionDensity: CGFloat = 0.55,
        text: String = "",
        textLineHeight: CGFloat = AnnotationTextMetrics.defaultNormalizedLineHeight,
        fontName: String = AnnotationTextMetrics.defaultFontName,
        isBold: Bool = true,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        textAlignment: NSTextAlignment = .left
    ) {
        self.id = id
        self.tool = tool
        self.rect = rect
        self.points = points
        self.swatch = swatch
        self.strokeWidth = strokeWidth
        self.redactionDensity = redactionDensity
        self.text = text
        self.textLineHeight = textLineHeight
        self.fontName = fontName
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.textAlignment = textAlignment
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        AnnotationTextMetrics.resolvedFont(
            name: fontName, size: size, bold: isBold, italic: isItalic
        )
    }

    var bounds: CGRect {
        switch tool {
        case .select:
            return rect.standardized

        case .line, .arrow, .freehand:
            let boundsPoints = tool == .arrow ? arrowPoints : points
            guard let first = boundsPoints.first else { return rect.standardized }
            let bounds = boundsPoints.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
                rect.union(CGRect(origin: point, size: .zero))
            }
            return bounds.standardized
        case .rectangle, .filledRectangle, .ellipse, .highlight, .numberedCircle, .pixelate, .blur, .spotlight, .text, .watermark, .tag:
            return rect.standardized
        }
    }

    var controlPoint: CGPoint? {
        guard tool == .arrow,
              let start = points.first,
              let end = points.last else {
            return nil
        }

        if points.count >= 3 {
            return points[1]
        }

        return CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
    }

    var arrowCurveHandle: CGPoint? {
        guard tool == .arrow,
              let start = points.first,
              let end = points.last,
              let control = controlPoint else {
            return nil
        }

        return CGPoint(
            x: 0.25 * start.x + 0.5 * control.x + 0.25 * end.x,
            y: 0.25 * start.y + 0.5 * control.y + 0.25 * end.y
        )
    }

    static func arrowControlPoint(forApex apex: CGPoint, start: CGPoint, end: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return CGPoint(x: 2 * apex.x - mid.x, y: 2 * apex.y - mid.y)
    }

    func isRenderable(minimumSize: CGFloat, allowEmptyText: Bool = false) -> Bool {
        switch tool {
        case .select:
            return false

        case .line:
            guard points.count == 2 else { return false }
            return hypot(points[0].x - points[1].x, points[0].y - points[1].y) >= minimumSize
        case .arrow:
            guard let start = points.first,
                  let end = points.last else {
                return false
            }

            return hypot(start.x - end.x, start.y - end.y) >= minimumSize
        case .freehand:
            guard points.count >= 2 else { return false }
            return pathLength(points) >= minimumSize
        case .rectangle, .filledRectangle, .ellipse, .highlight, .numberedCircle, .pixelate, .blur, .spotlight, .tag:
            return bounds.width >= minimumSize && bounds.height >= minimumSize
        case .text:
            return bounds.width >= minimumSize
                && bounds.height >= minimumSize
                && (allowEmptyText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .watermark:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func hitTest(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .select:
            return false

        case .line:
            guard let start = points.first,
                  let end = points.last else {
                return false
            }

            return distance(from: point, toSegmentFrom: start, to: end) <= tolerance

        case .freehand:
            guard points.count >= 2 else { return false }
            for index in 1..<points.count {
                if distance(from: point, toSegmentFrom: points[index - 1], to: points[index]) <= tolerance {
                    return true
                }
            }
            return false

        case .arrow:
            guard let start = points.first,
                  let controlPoint,
                  let end = points.last else {
                return false
            }

            return distance(from: point, toQuadraticFrom: start, control: controlPoint, to: end) <= tolerance

        case .rectangle, .filledRectangle, .highlight, .pixelate, .blur, .spotlight, .text, .watermark, .tag:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)

        case .ellipse, .numberedCircle:
            let expandedBounds = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            guard expandedBounds.width > 0, expandedBounds.height > 0 else { return false }

            let center = CGPoint(x: expandedBounds.midX, y: expandedBounds.midY)
            let normalizedX = (point.x - center.x) / (expandedBounds.width / 2)
            let normalizedY = (point.y - center.y) / (expandedBounds.height / 2)
            return normalizedX * normalizedX + normalizedY * normalizedY <= 1
        }
    }

    func offsetBy(_ delta: CGPoint) -> AnnotationItem {
        var item = self
        item.rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        item.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return item
    }

    func withEndpoint(_ handle: AnnotationResizeHandle, movedTo point: CGPoint) -> AnnotationItem {
        guard tool.usesEndpoints else { return self }

        var item = self
        if item.points.count < 2 {
            let fallback = item.points.first ?? point
            item.points = [fallback, fallback]
        }

        switch handle {
        case .start:
            item.ensureArrowPointStorage()
            item.points[0] = point
        case .control:
            guard item.tool == .arrow else { return self }
            item.ensureArrowPointStorage()
            item.points[1] = point
        case .end:
            item.ensureArrowPointStorage()
            item.points[item.points.count - 1] = point
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            return self
        }

        item.rect = item.bounds
        return item
    }

    func resized(to newBounds: CGRect) -> AnnotationItem {
        let oldBounds = bounds.standardized
        guard oldBounds.width > 0, oldBounds.height > 0 else {
            var item = self
            item.rect = newBounds
            return item
        }

        var item = self
        item.rect = newBounds
        item.points = points.map { point in
            CGPoint(
                x: newBounds.minX + ((point.x - oldBounds.minX) / oldBounds.width) * newBounds.width,
                y: newBounds.minY + ((point.y - oldBounds.minY) / oldBounds.height) * newBounds.height
            )
        }
        return item
    }

    private var arrowPoints: [CGPoint] {
        guard tool == .arrow,
              let start = points.first,
              let controlPoint,
              let end = points.last else {
            return points
        }

        return [start, controlPoint, end]
    }

    private mutating func ensureArrowPointStorage() {
        guard tool == .arrow,
              points.count == 2,
              let start = points.first,
              let end = points.last else {
            return
        }

        points = [start, CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), end]
    }

    private func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }

        var length: CGFloat = 0
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            length += hypot(current.x - previous.x, current.y - previous.y)
        }
        return length
    }

    private func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy

        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared
        let clampedProjection = min(max(projection, 0), 1)
        let closest = CGPoint(
            x: start.x + clampedProjection * dx,
            y: start.y + clampedProjection * dy
        )

        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private func distance(from point: CGPoint, toQuadraticFrom start: CGPoint, control: CGPoint, to end: CGPoint) -> CGFloat {
        var shortestDistance = CGFloat.greatestFiniteMagnitude
        var previous = start

        for step in 1...16 {
            let t = CGFloat(step) / 16
            let current = quadraticPoint(start: start, control: control, end: end, t: t)
            shortestDistance = min(shortestDistance, distance(from: point, toSegmentFrom: previous, to: current))
            previous = current
        }

        return shortestDistance
    }

    private func quadraticPoint(start: CGPoint, control: CGPoint, end: CGPoint, t: CGFloat) -> CGPoint {
        let first = CGPoint(
            x: start.x + (control.x - start.x) * t,
            y: start.y + (control.y - start.y) * t
        )
        let second = CGPoint(
            x: control.x + (end.x - control.x) * t,
            y: control.y + (end.y - control.y) * t
        )

        return CGPoint(
            x: first.x + (second.x - first.x) * t,
            y: first.y + (second.y - first.y) * t
        )
    }

    func remapped(from cropRect: CGRect) -> AnnotationItem {
        guard cropRect.width > 0, cropRect.height > 0 else { return self }
        var item = self
        item.rect = CGRect(
            x: (rect.origin.x - cropRect.origin.x) / cropRect.width,
            y: (rect.origin.y - cropRect.origin.y) / cropRect.height,
            width: rect.width / cropRect.width,
            height: rect.height / cropRect.height
        )
        item.points = points.map { p in
            CGPoint(
                x: (p.x - cropRect.origin.x) / cropRect.width,
                y: (p.y - cropRect.origin.y) / cropRect.height
            )
        }
        item.textLineHeight = textLineHeight / cropRect.height
        return item
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case freehand
    case highlight
    case text
    case numberedCircle
    case pixelate
    case blur
    case spotlight
    case watermark
    case tag

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "选择"
        case .rectangle: "方框"
        case .filledRectangle: "实心方框"
        case .ellipse: "圆形"
        case .line: "直线"
        case .arrow: "箭头"
        case .freehand: "画笔"
        case .highlight: "高亮"
        case .text: "文字"
        case .numberedCircle: "编号"
        case .pixelate: "像素化"
        case .blur: "打码"
        case .spotlight: "聚光"
        case .watermark: "水印"
        case .tag: "标签"
        }
    }

    var systemImage: String {
        switch self {
        case .select: "hand.point.up.left"
        case .rectangle: "rectangle"
        case .filledRectangle: "square.fill"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .freehand: "scribble"
        case .highlight: "highlighter"
        case .text: "t.square"
        case .numberedCircle: "1.circle.fill"
        case .pixelate: "app.background.dotted"
        case .blur: "drop.fill"
        case .spotlight: "light.max"
        case .watermark: "seal"
        case .tag: "tag.fill"
        }
    }

    var isFilledShape: Bool {
        self == .filledRectangle
    }

    var usesEndpoints: Bool {
        self == .line || self == .arrow
    }

    var isRedactionTool: Bool {
        self == .pixelate || self == .blur
    }

    var isSpotlightTool: Bool {
        self == .spotlight
    }

    var supportsAspectLock: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .highlight, .spotlight:
            true
        case .select, .line, .arrow, .freehand, .numberedCircle, .pixelate, .blur, .text, .watermark, .tag:
            false
        }
    }

    var createsAnnotation: Bool {
        self != .select
    }
}

struct AnnotationSwatch: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ id: String, title: String, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.id = id
        self.title = title
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var numberedCircleTextColor: Color {
        isLight ? .black : .white
    }

    var numberedCircleTextNSColor: NSColor {
        isLight ? .black : .white
    }

    var numberedCircleOutlineColor: Color {
        isLight ? Color.black.opacity(0.22) : Color.white.opacity(0.42)
    }

    var numberedCircleOutlineNSColor: NSColor {
        isLight ? NSColor.black.withAlphaComponent(0.22) : NSColor.white.withAlphaComponent(0.42)
    }

    private var isLight: Bool {
        (0.299 * red + 0.587 * green + 0.114 * blue) > 0.68
    }

    static let black = AnnotationSwatch("black", title: "黑色", red: 0.02, green: 0.02, blue: 0.024)
    static let red = AnnotationSwatch("red", title: "红色", red: 0.97, green: 0.22, blue: 0.2)
    static let orange = AnnotationSwatch("orange", title: "橙色", red: 1.0, green: 0.53, blue: 0.08)
    static let yellow = AnnotationSwatch("yellow", title: "黄色", red: 1, green: 0.82, blue: 0.18)
    /// 芥末黄：沉稳的高级黄（标注默认色）
    static let mustard = AnnotationSwatch("mustard", title: "芥末黄", red: 0.85, green: 0.64, blue: 0.25)
    /// 琥珀：黄向暖橙过渡
    static let amber = AnnotationSwatch("amber", title: "琥珀", red: 0.90, green: 0.56, blue: 0.17)
    /// 珊瑚红：沉稳的暖红（非艳红）
    static let coral = AnnotationSwatch("coral", title: "珊瑚红", red: 0.886, green: 0.341, blue: 0.298)
    /// 青碧：专业的青绿（低饱和高级感）
    static let teal = AnnotationSwatch("teal", title: "青碧", red: 0.122, green: 0.639, blue: 0.588)
    /// 靛蓝：克制的深蓝（区别于系统默认蓝）
    static let indigo = AnnotationSwatch("indigo", title: "靛蓝", red: 0.298, green: 0.373, blue: 0.835)
    static let green = AnnotationSwatch("green", title: "绿色", red: 0.18, green: 0.72, blue: 0.36)
    static let turquoise = AnnotationSwatch("turquoise", title: "青绿色", red: 0.20, green: 0.77, blue: 0.72)
    static let blue = AnnotationSwatch("blue", title: "蓝色", red: 0.18, green: 0.48, blue: 1)
    static let purple = AnnotationSwatch("purple", title: "紫色", red: 0.55, green: 0.30, blue: 0.95)
    static let pink = AnnotationSwatch("pink", title: "粉色", red: 1.0, green: 0.18, blue: 0.43)
    static let white = AnnotationSwatch("white", title: "白色", red: 0.96, green: 0.96, blue: 0.96)

    static let allCases: [AnnotationSwatch] = [
        .mustard, .coral, .teal, .indigo, .black, .white,
        .red, .orange, .yellow, .green, .turquoise, .blue, .purple, .pink, .amber
    ]

    static func custom(from color: Color) -> AnnotationSwatch {
        custom(from: NSColor(color))
    }

    static func custom(from nsColor: NSColor) -> AnnotationSwatch {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        let red = converted.redComponent
        let green = converted.greenComponent
        let blue = converted.blueComponent
        let alpha = converted.alphaComponent
        return AnnotationSwatch(
            "custom-\(Int(red * 255))-\(Int(green * 255))-\(Int(blue * 255))-\(Int(alpha * 255))",
            title: "自定义",
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}
