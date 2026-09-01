import AppKit

/// 悬浮条外观跟随背后画面亮度。
///
/// Liquid Glass 的底色明暗由背后的内容决定，而文字颜色（`Color.primary` 等）
/// 由窗口外观决定——两者不同步时（浅色外观遇上深色截图底），玻璃整体变黑、
/// 黑字跟着消失。这里采样工具栏背后的合成亮度：亮底给 aqua（浅玻璃配黑字），
/// 暗底给 darkAqua（深玻璃配白字），让底色和文字始终成对出现。
enum ToolbarBackdropAppearance {
    /// 平均亮度（sRGB gamma 空间）低于该值按深色底处理。0.5 ≈ 线性亮度 0.21，
    /// 大致是黑字/白字对比度曲线的交叉点。
    private static let darkThreshold: CGFloat = 0.5

    private static let fallbackLuminance: CGFloat = 0.03

    /// 工具栏背后合成画面的平均相对亮度（0=黑，1=白）。
    /// - Parameters:
    ///   - toolbarRect: 工具栏在画布视图坐标里的位置
    ///   - selectionRect: 选区在画布视图里的位置（ConfirmCanvasView.imageDrawRect）
    ///   - captureImage: 选区原图
    ///   - freezeImage: 蒙层退出后重新抓取的干净整屏画面（可为 nil）
    ///   - canvasBounds: 画布 bounds（定格帧铺满的范围）
    static func compositeLuminance(
        toolbarRect: CGRect,
        selectionRect: CGRect,
        captureImage: CGImage,
        freezeImage: CGImage?,
        canvasBounds: CGRect
    ) -> CGFloat? {
        let area = toolbarRect.width * toolbarRect.height
        guard area > 1, canvasBounds.width > 0, canvasBounds.height > 0 else { return nil }

        // 选区内部：原图原亮度
        var luminance: CGFloat = 0
        var covered: CGFloat = 0
        let overlap = toolbarRect.intersection(selectionRect)
        if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 {
            if let l = meanLuminance(of: captureImage, in: normalized(overlap, in: selectionRect)) {
                let fraction = overlap.width * overlap.height / area
                luminance += fraction * l
                covered = fraction
            }
        }

        // 选区外部：直接采样干净整屏画面。确认页不再覆盖全屏灰色暗幕，
        // 工具栏外观必须跟随用户真实看到的亮度。
        let outside = 1 - covered
        guard outside > 0.001 else { return luminance }
        let freezeLuminance: CGFloat
        if let freezeImage {
            freezeLuminance = meanLuminance(of: freezeImage, in: normalized(toolbarRect, in: canvasBounds))
                ?? fallbackLuminance
        } else {
            // 没有整屏帧时画布本身仍是深色回退底。
            freezeLuminance = fallbackLuminance
        }
        luminance += outside * freezeLuminance
        return luminance
    }

    /// 亮度对应的外观名。面板外观同时决定玻璃的明暗变体和文字深浅。
    static func appearanceName(forLuminance luminance: CGFloat) -> NSAppearance.Name {
        luminance < darkThreshold ? .darkAqua : .aqua
    }

    /// 归一化区域的平均亮度：裁出原图，降到 16×16 后做感知加权平均。
    /// gamma 空间的均值对“亮底还是暗底”的判断足够，也免去逐像素线性化。
    private static func meanLuminance(of image: CGImage, in normalizedRect: CGRect) -> CGFloat? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        // 视图归一化坐标左下为原点，CGImage 像素左上为原点，Y 翻转
        let crop = CGRect(
            x: normalizedRect.minX * bounds.width,
            y: (1 - normalizedRect.maxY) * bounds.height,
            width: normalizedRect.width * bounds.width,
            height: normalizedRect.height * bounds.height
        ).intersection(bounds).integral
        guard crop.width >= 1, crop.height >= 1, let cropped = image.cropping(to: crop) else { return nil }

        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8,
                  bytesPerRow: side * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = ctx.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        var total = 0.0
        for index in 0..<(side * side) {
            let offset = index * 4
            total += 0.2126 * Double(pixels[offset])
                + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])
        }
        return CGFloat(total / Double(side * side) / 255.0)
    }

    /// 视图 rect → 相对 container 的归一化 rect（都是左下原点，不翻 Y）。
    private static func normalized(_ rect: CGRect, in container: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - container.minX) / container.width,
            y: (rect.minY - container.minY) / container.height,
            width: rect.width / container.width,
            height: rect.height / container.height
        )
    }
}
