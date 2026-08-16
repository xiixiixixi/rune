import CoreGraphics

/// 多显示器坐标换算与跨屏矩形计算（纯函数，无 AppKit / SCK 依赖，可独立测试）。
///
/// 设计依据：M1 设计文档 §3.3 —— 坐标换算和拼接算法必须是独立、可自动测试的纯函数。
///
/// 坐标系约定（三套空间）：
/// - 点空间：全局 AppKit 点坐标，原点在**左下角**，单位：点（pt）
/// - 显示器像素空间：每块屏幕独立，原点在**左上角**，单位：像素（px）
/// - 拼接画布：跨屏截图的输出空间，原点在**左上角**，单位：像素（px）；
///   画布 = 点空间布局按**统一倍率**放大（倍率取所有屏的最大值），
///   每块屏的像素内容按其在全局布局中的位置放置。
public enum DisplayLayout {

    /// 所有显示器的全局布局范围（点空间）
    public static func layoutBounds(of displays: [DisplayDescriptor]) -> CGRect {
        displays.reduce(CGRect.null) { $0.union($1.frame) }
    }

    /// 显示器自身的像素帧（原点左上，尺寸 = 点尺寸 × 缩放倍率）
    public static func pixelFrame(of display: DisplayDescriptor) -> CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: display.frame.width * display.backingScaleFactor,
            height: display.frame.height * display.backingScaleFactor
        )
    }

    /// 全局点空间矩形 → 该显示器**局部**像素空间矩形（原点左上，物理像素）
    ///
    /// 推导：点空间原点左下。显示器 D 的 frame 为 (fx, fy, fw, fh)（全局点坐标）。
    /// 全局矩形 R 与 D 的交集 I（点空间）内任一点 p：
    ///   相对 D 左下角 = (p.x - fx, p.y - fy)
    ///   像素空间（左上原点）: x_px = (p.x - fx) * s, y_px = (fh - (p.y - fy)) * s
    /// 因此交集矩形（左上原点）：
    ///   x_px = (I.minX - fx) * s
    ///   y_px = (fh - I.maxY) * s          ← 矩形的"上边"对应全局最大 y
    ///   w_px = I.width * s, h_px = I.height * s
    public static func pixelRect(in display: DisplayDescriptor, for globalRect: CGRect) -> CGRect {
        let s = display.backingScaleFactor
        let f = display.frame
        let intersection = globalRect.intersection(f)
        guard !intersection.isNull else { return .null }
        return CGRect(
            x: (intersection.minX - f.minX) * s,
            y: (f.height - (intersection.maxY - f.minY)) * s,
            width: intersection.width * s,
            height: intersection.height * s
        )
    }

    /// 全局点空间矩形与各显示器的交集（点空间），只返回非空交集
    public static func intersections(
        of globalRect: CGRect,
        with displays: [DisplayDescriptor]
    ) -> [(display: DisplayDescriptor, intersection: CGRect)] {
        displays.compactMap { display in
            let i = globalRect.intersection(display.frame)
            return i.isNull ? nil : (display, i)
        }
    }

    /// 拼接画布布局：所有显示器的全局布局按统一倍率放大，
    /// 返回画布尺寸与每块屏在画布中的像素帧（全局像素坐标，原点左上）。
    ///
    /// 混屏取舍：统一倍率取最大 backingScaleFactor（Retina 屏的 2x），
    /// 低倍率屏（1x）的图像在画布中会被拉伸到同一点尺寸——
    /// 点尺寸一致（内容大小正确），低倍率屏局部清晰度降低，这是混屏拼接的固有取舍。
    public static func canvasLayout(
        displays: [DisplayDescriptor]
    ) -> (canvasSize: CGSize, frames: [(displayID: CGDirectDisplayID, pixelFrame: CGRect)]) {
        let layout = layoutBounds(of: displays)
        let scale = displays.map(\.backingScaleFactor).max() ?? 1
        let canvasSize = CGSize(width: layout.width * scale, height: layout.height * scale)
        let frames = displays.map { display in
            CGRect(
                x: (display.frame.minX - layout.minX) * scale,
                y: (layout.maxY - display.frame.maxY) * scale,  // 左上原点：从布局顶部往下数
                width: display.frame.width * scale,
                height: display.frame.height * scale
            )
        }
        return (canvasSize, zip(displays.map(\.id), frames).map { (displayID: $0.0, pixelFrame: $0.1) })
    }

    /// 跨屏截图的像素矩形收集（全局像素坐标，用于拼接）：
    /// 给定全局点空间选区，返回每个相交显示器在画布中应写入的像素矩形，
    /// 按"主屏优先、其余按全局 x 从左到右"排序，调用方依序逐屏 capture 后按画布坐标拼接。
    public static func pixelRects(
        for globalRect: CGRect,
        displays: [DisplayDescriptor],
        primaryID: CGDirectDisplayID?
    ) -> [(displayID: CGDirectDisplayID, pixelRect: CGRect)] {
        let (_, frames) = canvasLayout(displays: displays)
        let frameByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.displayID, $0.pixelFrame) })

        return intersections(of: globalRect, with: displays)
            .sorted { lhs, rhs in
                let lhsPrimary = lhs.display.id == primaryID
                let rhsPrimary = rhs.display.id == primaryID
                if lhsPrimary != rhsPrimary { return lhsPrimary }
                return lhs.display.frame.minX < rhs.display.frame.minX
            }
            .compactMap { item in
                guard let canvasFrame = frameByID[item.display.id] else { return nil }
                // 交集（点空间）按统一倍率放到画布坐标，再与该屏画布帧求交集（裁剪到屏内）
                let scale = displays.map(\.backingScaleFactor).max() ?? 1
                let layout = layoutBounds(of: displays)
                let i = item.intersection
                let canvasRect = CGRect(
                    x: (i.minX - layout.minX) * scale,
                    y: (layout.maxY - i.maxY) * scale,
                    width: i.width * scale,
                    height: i.height * scale
                )
                let clipped = canvasRect.intersection(canvasFrame)
                return clipped.isNull ? nil : (item.display.id, clipped)
            }
    }
}
