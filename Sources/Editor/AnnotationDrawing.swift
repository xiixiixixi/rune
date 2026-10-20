import CoreGraphics
@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

enum AnnotationDrawing {

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func draw(_ items: [AnnotationItem], in ctx: CGContext, imageRect: CGRect, fullCanvasRect: CGRect, sourceImage: CGImage?, flipped: Bool = false, minimumTextFontSize: CGFloat = AnnotationTextMetrics.minimumFontSize) {
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let hasRedaction = items.contains { $0.tool.isRedactionTool }
        let canvasSnapshot: CGImage? = hasRedaction ? ctx.makeImage() : nil

        for item in items {
            autoreleasepool {
                ctx.setStrokeColor(item.swatch.nsColor.cgColor)
                ctx.setFillColor(item.swatch.nsColor.cgColor)

                let lineWidth = renderedLineWidth(for: item, imageSize: imageRect.size)
                ctx.setLineWidth(lineWidth)

                switch item.tool {
                case .select:
                    return

                case .rectangle:
                    ctx.stroke(renderedRect(item.bounds, in: imageRect, flipped: flipped))

                case .filledRectangle:
                    let rect = renderedRect(item.bounds, in: imageRect, flipped: flipped)
                    ctx.addPath(CGPath(
                        roundedRect: rect,
                        cornerWidth: AnnotationFilledRectangleMetrics.cornerRadius(for: rect),
                        cornerHeight: AnnotationFilledRectangleMetrics.cornerRadius(for: rect),
                        transform: nil
                    ))
                    ctx.fillPath()

                case .highlight:
                    // 荧光笔：multiply 混合保留底图文字可读性（飞书 draw_highlight 同款）
                    ctx.saveGState()
                    ctx.setBlendMode(.multiply)
                    ctx.setFillColor(AnnotationHighlightMetrics.highlightColor(for: item.swatch).cgColor)
                    ctx.fill(renderedRect(item.bounds, in: imageRect, flipped: flipped))
                    ctx.restoreGState()

                case .ellipse:
                    ctx.strokeEllipse(in: renderedRect(item.bounds, in: imageRect, flipped: flipped))

                case .numberedCircle:
                    drawNumberedCircle(item, in: renderedRect(item.bounds, in: imageRect, flipped: flipped), context: ctx, flipped: flipped)

                case .pixelate:
                    guard let canvasSnapshot else { return }
                    applyPixelation(
                        in: renderedRect(item.bounds, in: imageRect, flipped: flipped),
                        canvasSnapshot: canvasSnapshot,
                        context: ctx,
                        canvasSize: fullCanvasRect.size,
                        colorSpace: CGColorSpaceCreateDeviceRGB(),
                        density: item.redactionDensity,
                        flipped: flipped
                    )

                case .blur:
                    guard let canvasSnapshot else { return }
                    applyBlur(
                        in: renderedRect(item.bounds, in: imageRect, flipped: flipped),
                        canvasSnapshot: canvasSnapshot,
                        context: ctx,
                        canvasSize: fullCanvasRect.size,
                        density: item.redactionDensity,
                        flipped: flipped
                    )

                case .spotlight:
                    let targetRect = renderedRect(item.bounds, in: imageRect, flipped: flipped)
                    let overlayColor = CGColor(gray: 0, alpha: item.redactionDensity)
                    ctx.saveGState()
                    let fullPath = CGMutablePath()
                    fullPath.addRect(fullCanvasRect)
                    fullPath.addRect(targetRect)
                    ctx.addPath(fullPath)
                    ctx.setFillColor(overlayColor)
                    ctx.fillPath(using: .evenOdd)
                    ctx.restoreGState()

                case .text:
                    drawText(item, in: renderedRect(item.bounds, in: imageRect, flipped: flipped), imageHeight: imageRect.height, context: ctx, flipped: flipped, minimumFontSize: minimumTextFontSize)

                case .watermark:
                    drawWatermark(item, in: imageRect, context: ctx, flipped: flipped)

                case .tag:
                    guard let anchorPoint = item.points.first else { return }
                    drawTag(
                        item,
                        in: renderedRect(item.bounds, in: imageRect, flipped: flipped),
                        anchor: renderedPoint(anchorPoint, in: imageRect, flipped: flipped),
                        imageHeight: imageRect.height,
                        context: ctx,
                        flipped: flipped
                    )

                case .line:
                    guard let first = item.points.first,
                          let last = item.points.last else { return }
                    let start = renderedPoint(first, in: imageRect, flipped: flipped)
                    let end = renderedPoint(last, in: imageRect, flipped: flipped)
                    ctx.beginPath()
                    ctx.move(to: start)
                    ctx.addLine(to: end)
                    ctx.strokePath()

                case .freehand:
                    drawFreehand(points: item.points, imageRect: imageRect, context: ctx, flipped: flipped)

                case .arrow:
                    guard let first = item.points.first,
                          let control = item.controlPoint,
                          let last = item.points.last,
                          let geometry = AnnotationArrowGeometry(
                            start: renderedPoint(first, in: imageRect, flipped: flipped),
                            control: renderedPoint(control, in: imageRect, flipped: flipped),
                            end: renderedPoint(last, in: imageRect, flipped: flipped),
                            lineWidth: lineWidth
                          ) else { return }
                    ctx.beginPath()
                    ctx.move(to: renderedPoint(first, in: imageRect, flipped: flipped))
                    ctx.addQuadCurve(to: geometry.tip, control: geometry.shaftControl)
                    ctx.strokePath()
                    drawArrowHead(geometry, context: ctx)
                }
            }
        }
    }

    static func draw(_ items: [AnnotationItem], in ctx: CGContext, canvasSize: CGSize, sourceImage: CGImage?) {
        let rect = CGRect(origin: .zero, size: canvasSize)
        draw(items, in: ctx, imageRect: rect, fullCanvasRect: rect, sourceImage: sourceImage)
    }

    private static func renderedRect(_ rect: CGRect, in imageRect: CGRect, flipped: Bool = false) -> CGRect {
        if flipped {
            return CGRect(
                x: imageRect.minX + rect.minX * imageRect.width,
                y: imageRect.minY + rect.minY * imageRect.height,
                width: rect.width * imageRect.width,
                height: rect.height * imageRect.height
            )
        }
        return CGRect(
            x: imageRect.minX + rect.minX * imageRect.width,
            y: imageRect.minY + (1 - rect.maxY) * imageRect.height,
            width: rect.width * imageRect.width,
            height: rect.height * imageRect.height
        )
    }

    private static func renderedPoint(_ point: CGPoint, in imageRect: CGRect, flipped: Bool = false) -> CGPoint {
        if flipped {
            return CGPoint(
                x: imageRect.minX + point.x * imageRect.width,
                y: imageRect.minY + point.y * imageRect.height
            )
        }
        return CGPoint(
            x: imageRect.minX + point.x * imageRect.width,
            y: imageRect.minY + (1 - point.y) * imageRect.height
        )
    }

    private static func drawArrowHead(_ geometry: AnnotationArrowGeometry, context: CGContext) {
        context.beginPath()
        context.move(to: geometry.firstWing)
        context.addLine(to: geometry.tip)
        context.addLine(to: geometry.secondWing)
        context.strokePath()
    }

    private static func drawNumberedCircle(_ item: AnnotationItem, in rect: CGRect, context: CGContext, flipped: Bool = false) {
        let diameter = min(rect.width, rect.height)
        guard diameter > 1 else { return }

        let outlineWidth = AnnotationNumberedCircleMetrics.outlineWidth(for: diameter)
        context.saveGState()
        context.setFillColor(item.swatch.nsColor.cgColor)
        context.fillEllipse(in: rect)
        context.setStrokeColor(item.swatch.numberedCircleOutlineNSColor.cgColor)
        context.setLineWidth(outlineWidth)
        context.strokeEllipse(in: rect.insetBy(dx: outlineWidth / 2, dy: outlineWidth / 2))
        context.restoreGState()

        let fontSize = AnnotationNumberedCircleMetrics.fontSize(for: diameter, text: item.text)
        let font = RuneFont.appKit(size: fontSize, weight: .bold)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byClipping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.swatch.numberedCircleTextNSColor,
            .paragraphStyle: paragraphStyle
        ]
        let attributedText = NSAttributedString(string: item.text, attributes: attributes)
        let measuredRect = attributedText.boundingRect(
            with: CGSize(width: rect.width, height: rect.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textRect = CGRect(
            x: rect.minX,
            y: rect.midY - measuredRect.height / 2 - fontSize * 0.04,
            width: rect.width,
            height: measuredRect.height + 2
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawFreehand(points: [CGPoint], imageRect: CGRect, context: CGContext, flipped: Bool = false) {
        let renderedPoints = points.map { renderedPoint($0, in: imageRect, flipped: flipped) }
        guard let first = renderedPoints.first else { return }

        context.beginPath()
        context.move(to: first)
        guard renderedPoints.count > 1 else { return }

        if renderedPoints.count == 2 {
            context.addLine(to: renderedPoints[1])
            context.strokePath()
            return
        }

        for index in 1..<renderedPoints.count {
            let previous = renderedPoints[index - 1]
            let current = renderedPoints[index]
            context.addQuadCurve(to: midpoint(previous, current), control: previous)
        }

        context.addLine(to: renderedPoints[renderedPoints.count - 1])
        context.strokePath()
    }

    private static func midpoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: (lhs.x + rhs.x) / 2, y: (lhs.y + rhs.y) / 2)
    }

    private static func drawText(_ item: AnnotationItem, in rect: CGRect, imageHeight: CGFloat, context: CGContext, flipped: Bool = false, minimumFontSize: CGFloat = AnnotationTextMetrics.minimumFontSize) {
        let text = item.text.trimmingCharacters(in: .newlines)
        let minimumExtent: CGFloat = minimumFontSize < 1 ? 0.1 : 1
        guard !text.isEmpty, rect.width > minimumExtent, rect.height > minimumExtent else { return }

        let fontSize = max(item.textLineHeight * imageHeight * AnnotationTextMetrics.fontScale, minimumFontSize)
        let font = item.resolvedFont(size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = item.textAlignment
        paragraphStyle.lineBreakMode = .byWordWrapping

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.swatch.nsColor,
            .paragraphStyle: paragraphStyle,
            .shadow: AnnotationTextMetrics.textShadow
        ]
        if item.isUnderline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        let attributedText = NSAttributedString(string: text, attributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: flipped)
        attributedText.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 指向性标注气泡（飞书「标签」同款）：锚点红点 + 深色圆角气泡 + 指向锚点的三角尖。
    /// 气泡里的文字始终是白色（底色固定为深色），不跟随标注色点。
    private static func drawTag(
        _ item: AnnotationItem,
        in rect: CGRect,
        anchor: CGPoint,
        imageHeight: CGFloat,
        context ctx: CGContext,
        flipped: Bool
    ) {
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        ctx.setFillColor(AnnotationTagMetrics.bubbleColor.cgColor)
        // 三角尖先画、气泡后盖：两者同色，接缝不会露出底图
        ctx.addPath(AnnotationTagMetrics.tailPath(
            bubble: rect,
            anchor: anchor,
            tailLength: rect.width * 0.16
        ))
        ctx.fillPath()

        let corner = min(rect.height * 0.24, 14)
        ctx.addPath(CGPath(
            roundedRect: rect,
            cornerWidth: corner,
            cornerHeight: corner,
            transform: nil
        ))
        ctx.fillPath()

        let dotRadius = imageHeight * AnnotationTagMetrics.normalizedDotDiameter / 2
        if dotRadius > 0.4 {
            ctx.setFillColor(AnnotationTagMetrics.dotColor.cgColor)
            ctx.fillEllipse(in: CGRect(
                x: anchor.x - dotRadius,
                y: anchor.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            ))
        }

        let text = item.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }
        let inset = rect.height * 0.15
        let textRect = rect.insetBy(dx: inset, dy: inset * 0.7)
        guard textRect.width > 1, textRect.height > 1 else { return }
        let fontSize = max(item.textLineHeight * imageHeight * AnnotationTextMetrics.fontScale, 9)
        let font = item.resolvedFont(size: fontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        let attributedText = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: AnnotationTagMetrics.textColor,
            .paragraphStyle: paragraphStyle
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: flipped)
        attributedText.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 全图斜排水印（飞书水印工具同款）：文字按 30° 倾斜、等距平铺、隔行错位，
    /// 不透明度走 redactionDensity（默认 0.34），颜色跟随标注色点。
    private static func drawWatermark(_ item: AnnotationItem, in imageRect: CGRect, context ctx: CGContext, flipped: Bool = false) {
        let text = item.text.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return }

        let fontSize = max(item.textLineHeight * imageRect.height * AnnotationTextMetrics.fontScale, 9)
        let font = item.resolvedFont(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: item.swatch.nsColor.withAlphaComponent(item.redactionDensity),
        ]
        let measured = (text as NSString).size(withAttributes: attributes)
        guard measured.width > 1, measured.height > 1 else { return }

        let stepX = measured.width + fontSize * AnnotationWatermarkMetrics.spacingScaleX
        let stepY = measured.height + fontSize * AnnotationWatermarkMetrics.spacingScaleY
        guard stepX > 1, stepY > 1 else { return }

        ctx.saveGState()
        // 1) 裁剪在设备空间做：水印只落在图片范围内
        ctx.clip(to: [imageRect])

        // 2) 坐标系挪到图中心并归一成 Y-down，再旋转出斜排角度。
        //    Y-down 里正角=顺时针，文字呈现左上→右下的「\」方向。
        ctx.translateBy(x: imageRect.midX, y: imageRect.midY)
        if !flipped {
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.rotate(by: AnnotationWatermarkMetrics.tiltAngle)

        // 3) 旋转后的网格要盖住原矩形的对角外接范围，四角才不空
        let diagonal = hypot(imageRect.width, imageRect.height) + stepX
        let columns = Int(ceil(diagonal / stepX))
        let rows = Int(ceil((imageRect.height + diagonal) / stepY))
        guard columns > 0, columns < 512, rows > 0, rows < 512 else {
            ctx.restoreGState()
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

        let string = text as NSString
        let startY = -CGFloat(rows - 1) * stepY / 2
        let startX = -CGFloat(columns) * stepX / 2
        for row in 0..<rows {
            // 隔行错开半个间距，避免长文字排成呆板的矩阵
            let rowOffset = (row % 2 == 1) ? stepX / 2 : 0
            for column in 0...columns {
                string.draw(
                    at: CGPoint(x: startX + CGFloat(column) * stepX + rowOffset, y: startY + CGFloat(row) * stepY),
                    withAttributes: attributes
                )
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private static func applyPixelation(
        in rect: CGRect,
        canvasSnapshot: CGImage,
        context: CGContext,
        canvasSize: CGSize,
        colorSpace: CGColorSpace,
        density: CGFloat,
        flipped: Bool = false
    ) {
        let targetRect = rect.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard targetRect.width >= 1,
              targetRect.height >= 1,
              let croppedImage = canvasSnapshot.cropping(to: imageCropRect(for: targetRect, imageHeight: CGFloat(canvasSnapshot.height), flipped: flipped)) else {
            return
        }

        let pixelSize = RedactionImageProcessor.pixelBlockSize(for: density)
        let lowWidth = max(1, Int(targetRect.width / pixelSize))
        let lowHeight = max(1, Int(targetRect.height / pixelSize))

        guard let lowContext = CGContext(
            data: nil, width: lowWidth, height: lowHeight,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }

        lowContext.interpolationQuality = .medium
        lowContext.draw(croppedImage, in: CGRect(x: 0, y: 0, width: lowWidth, height: lowHeight))
        guard let pixelatedImage = lowContext.makeImage() else { return }

        context.saveGState()
        context.clip(to: targetRect)
        context.interpolationQuality = .none
        if flipped {
            context.translateBy(x: targetRect.minX, y: targetRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(pixelatedImage, in: CGRect(x: 0, y: 0, width: targetRect.width, height: targetRect.height))
        } else {
            context.draw(pixelatedImage, in: targetRect)
        }
        context.restoreGState()
    }

    private static func applyBlur(
        in rect: CGRect,
        canvasSnapshot: CGImage,
        context: CGContext,
        canvasSize: CGSize,
        density: CGFloat,
        flipped: Bool = false
    ) {
        let targetRect = rect.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard targetRect.width >= 1,
              targetRect.height >= 1,
              let croppedImage = canvasSnapshot.cropping(to: imageCropRect(for: targetRect, imageHeight: CGFloat(canvasSnapshot.height), flipped: flipped)) else {
            return
        }

        let radius = RedactionImageProcessor.blurRadius(for: density)
        let fullImageRect = CGRect(x: 0, y: 0, width: canvasSnapshot.width, height: canvasSnapshot.height)
        let cropRectInImage = imageCropRect(for: targetRect, imageHeight: CGFloat(canvasSnapshot.height), flipped: flipped)
        let paddedCropRect = cropRectInImage
            .insetBy(dx: -ceil(radius * 2), dy: -ceil(radius * 2))
            .intersection(fullImageRect)
            .integral

        let paddedImage: CGImage
        if let padded = canvasSnapshot.cropping(to: paddedCropRect) {
            paddedImage = padded
        } else {
            paddedImage = croppedImage
        }

        let inputImage = CIImage(cgImage: paddedImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = inputImage.clampedToExtent()
        filter.radius = Float(radius)

        let outputRect = CGRect(
            x: cropRectInImage.minX - paddedCropRect.minX,
            y: cropRectInImage.minY - paddedCropRect.minY,
            width: cropRectInImage.width,
            height: cropRectInImage.height
        )

        guard let outputImage = filter.outputImage,
              let blurredImage = ciContext.createCGImage(outputImage, from: outputRect) else {
            return
        }

        context.saveGState()
        context.clip(to: targetRect)
        if flipped {
            context.translateBy(x: targetRect.minX, y: targetRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(blurredImage, in: CGRect(x: 0, y: 0, width: targetRect.width, height: targetRect.height))
        } else {
            context.draw(blurredImage, in: targetRect)
        }
        context.restoreGState()
        ciContext.clearCaches()
    }

    private static func renderedLineWidth(for item: AnnotationItem, imageSize: CGSize) -> CGFloat {
        max(1.5, item.strokeWidth * max(imageSize.width, imageSize.height) / 900)
    }

    private static func imageCropRect(for contextRect: CGRect, imageHeight: CGFloat, flipped: Bool = false) -> CGRect {
        if flipped {
            return CGRect(
                x: contextRect.minX,
                y: contextRect.minY,
                width: contextRect.width,
                height: contextRect.height
            ).integral
        }
        return CGRect(
            x: contextRect.minX,
            y: imageHeight - contextRect.maxY,
            width: contextRect.width,
            height: contextRect.height
        ).integral
    }
}
