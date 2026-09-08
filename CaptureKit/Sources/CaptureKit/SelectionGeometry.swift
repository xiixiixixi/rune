import CoreGraphics

/// 选区几何：把拖拽点/矩形规范到屏幕内的纯函数集合。
///
/// 背景：拖框点从不越界钳制时，相邻双屏上拖全屏框很容易把松手点甩到
/// 另一块屏（坐标越过本屏边界），下游裁剪对越界选区一票否决，
/// 表现为「选区范围无效」——全屏截图高发失败。系统截图工具的做法是
/// 选区永远吸附在屏幕内：这里提供同一套规则，交互层与裁剪层共用。
public enum SelectionGeometry {

    // MARK: - 点

    /// 把点钳制进矩形范围（x/y 各自 min-max 收拢）。
    public static func clamped(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// 钳制后做屏幕边缘磁吸：距任一边 ≤ radius 时贴齐该边。
    /// 拖到屏幕边缘时选区自动"锁"在边上，配合近全屏贴齐让全屏框选一次到位。
    public static func magnetized(
        _ point: CGPoint,
        in bounds: CGRect,
        radius: CGFloat
    ) -> CGPoint {
        var p = clamped(point, to: bounds)
        if abs(p.x - bounds.minX) <= radius { p.x = bounds.minX }
        if abs(p.x - bounds.maxX) <= radius { p.x = bounds.maxX }
        if abs(p.y - bounds.minY) <= radius { p.y = bounds.minY }
        if abs(p.y - bounds.maxY) <= radius { p.y = bounds.maxY }
        return p
    }

    // MARK: - 矩形

    /// 近全屏贴齐：矩形宽、高都达到屏幕对应尺寸的 coverage 比例（默认 95%）
    /// 时返回整屏矩形。覆盖 95% 以上几乎只可能是"想截全屏但没拖到角"，
    /// 贴齐后不再产出缺一两像素的"伪全屏"。
    public static func fullScreenSnapped(
        _ rect: CGRect,
        in bounds: CGRect,
        coverage: CGFloat = 0.95
    ) -> CGRect {
        guard rect.width >= bounds.width * coverage,
              rect.height >= bounds.height * coverage else { return rect }
        return bounds
    }

    /// 点对（起点可来自 mouseDown、终点可来自 mouseUp）规范化为最终选区：
    /// 双端钳制 → 终点磁吸 → 近全屏贴齐。
    public static func selectionRect(
        from start: CGPoint,
        to end: CGPoint,
        in bounds: CGRect,
        magnetRadius: CGFloat
    ) -> CGRect {
        let s = clamped(start, to: bounds)
        let e = magnetized(end, in: bounds, radius: magnetRadius)
        let rect = CGRect(
            x: min(s.x, e.x),
            y: min(s.y, e.y),
            width: abs(e.x - s.x),
            height: abs(e.y - s.y)
        )
        return fullScreenSnapped(rect, in: bounds)
    }

    // MARK: - 显示器帧裁剪

    /// 把全局 CG 点坐标选区换算成某显示器截图上的像素矩形，并钳制到图像内。
    ///
    /// 返回 nil 表示选区与该显示器完全不相交（宽或高 < 1 像素）。
    /// 越界部分裁掉即可、不判死：窗口半出屏、比例约束顶出屏幕、换算尾差
    /// 都不该让整次截图失败（旧行为对越界一票否决，是全屏框选高发
    /// 「选区范围无效」的直接原因）。
    public static func visiblePixelRect(
        pointsRect: CGRect,
        displayBounds: CGRect,
        imageSize: CGSize
    ) -> CGRect? {
        guard displayBounds.width >= 1, displayBounds.height >= 1 else { return nil }
        let scale = CGFloat(imageSize.width) / displayBounds.width
        let local = CGRect(
            x: pointsRect.minX - displayBounds.minX,
            y: pointsRect.minY - displayBounds.minY,
            width: pointsRect.width,
            height: pointsRect.height
        )
        let pixelRect = CGRect(
            x: local.minX * scale,
            y: local.minY * scale,
            width: local.width * scale,
            height: local.height * scale
        ).integral
        let visible = pixelRect.intersection(
            CGRect(origin: .zero, size: imageSize)
        )
        guard visible.width >= 1, visible.height >= 1 else { return nil }
        return visible
    }
}
