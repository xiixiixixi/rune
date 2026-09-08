import CoreGraphics
import Testing
@testable import CaptureKit

/// 选区几何测试：钳制、边缘磁吸、近全屏贴齐——对应"双屏拖全屏框越界导致
/// 选区无效"的回归（拖到相邻屏、松手点出界都必须收敛到屏幕内）。
@Suite struct SelectionGeometryTests {

    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let magnet: CGFloat = 8

    // MARK: - clamped

    @Test func clampPullsPointIntoBounds() {
        // 双屏相邻：拖到右邻屏上，坐标越过本屏右缘
        let right = SelectionGeometry.clamped(CGPoint(x: 1935, y: -8), to: screen)
        #expect(right == CGPoint(x: 1920, y: 0))
        let left = SelectionGeometry.clamped(CGPoint(x: -12, y: 500), to: screen)
        #expect(left == CGPoint(x: 0, y: 500))
        // 界内点不动
        let inside = SelectionGeometry.clamped(CGPoint(x: 100, y: 100), to: screen)
        #expect(inside == CGPoint(x: 100, y: 100))
    }

    @Test func clampHandlesNonZeroOrigin() {
        // 副屏位于主屏右侧：局部边界从 (1920, 0) 起
        let secondary = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let p = SelectionGeometry.clamped(CGPoint(x: 1910, y: -5), to: secondary)
        #expect(p == CGPoint(x: 1920, y: 0))
    }

    // MARK: - magnetized

    @Test func magnetSnapsWithinRadius() {
        let nearEdge = SelectionGeometry.magnetized(CGPoint(x: 5, y: 500), in: screen, radius: magnet)
        #expect(nearEdge.x == 0)
        let nearCorner = SelectionGeometry.magnetized(
            CGPoint(x: 1915, y: 1078), in: screen, radius: magnet
        )
        #expect(nearCorner == CGPoint(x: 1920, y: 1080))
    }

    @Test func magnetIgnoresPointsBeyondRadius() {
        let p = SelectionGeometry.magnetized(CGPoint(x: 9, y: 500), in: screen, radius: magnet)
        #expect(p == CGPoint(x: 9, y: 500))
    }

    @Test func magnetClampsBeforeSnapping() {
        // 越界点先被拉回边缘，再自然贴齐（越界 → 精确边缘）
        let p = SelectionGeometry.magnetized(CGPoint(x: -30, y: 20), in: screen, radius: magnet)
        #expect(p == CGPoint(x: 0, y: 20))
    }

    // MARK: - fullScreenSnapped

    @Test func nearFullScreenSnapsToExactBounds() {
        // 拖了 97% 宽 × 96% 高：按"想截全屏没拖到角"处理
        let sloppy = CGRect(x: 15, y: 10, width: 1900, height: 1037)
        #expect(SelectionGeometry.fullScreenSnapped(sloppy, in: screen) == screen)
    }

    @Test func partialSelectionDoesNotSnap() {
        // 宽达标但高只有一半：不贴齐
        let wide = CGRect(x: 0, y: 0, width: 1920, height: 540)
        #expect(SelectionGeometry.fullScreenSnapped(wide, in: screen) == wide)
        // 排除菜单栏/程序坞的 90% 高度选区不被劫持
        let dockless = CGRect(x: 0, y: 0, width: 1920, height: 1000)
        #expect(SelectionGeometry.fullScreenSnapped(dockless, in: screen) == dockless)
    }

    // MARK: - selectionRect（mouseUp 全链路）

    @Test func selectionRectSurvivesOvershootOntoNeighborDisplay() {
        // 回归主场景：从左上角拖向右下角，松手点甩到右邻屏外
        let rect = SelectionGeometry.selectionRect(
            from: CGPoint(x: 2, y: 3),
            to: CGPoint(x: 1990, y: 1100),
            in: screen,
            magnetRadius: magnet
        )
        #expect(rect == screen)
    }

    @Test func selectionRectKeepsSmallDragPrecise() {
        // 小区域框选：磁吸与贴齐都不应介入
        let rect = SelectionGeometry.selectionRect(
            from: CGPoint(x: 100, y: 100),
            to: CGPoint(x: 500, y: 400),
            in: screen,
            magnetRadius: magnet
        )
        #expect(rect == CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    @Test func selectionRectClampsInvertedDragDirection() {
        // 从右下往左上拖，起点也越界
        let rect = SelectionGeometry.selectionRect(
            from: CGPoint(x: 1980, y: 1090),
            to: CGPoint(x: -20, y: -10),
            in: screen,
            magnetRadius: magnet
        )
        #expect(rect == screen)
    }

    // MARK: - visiblePixelRect（选区 → 显示器帧上的像素矩形）

    /// 回归主场景：4K@2x 主屏（1920×1080 点 → 3840×2160 像素），
    /// 拖全屏框松手点甩过右缘 70 点。旧实现直接判 nil（选区范围无效），
    /// 新实现必须裁回图像内。
    @Test func overshootCropsToImageInsteadOfFailing() {
        let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let imageSize = CGSize(width: 3840, height: 2160)
        let overshoot = CGRect(x: 0, y: 0, width: 1990, height: 1080)
        let rect = SelectionGeometry.visiblePixelRect(
            pointsRect: overshoot,
            displayBounds: displayBounds,
            imageSize: imageSize
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 3840, height: 2160))
    }

    @Test func exactFullScreenYieldsWholeImage() {
        let rect = SelectionGeometry.visiblePixelRect(
            pointsRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            imageSize: CGSize(width: 3840, height: 2160)
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 3840, height: 2160))
    }

    @Test func secondaryDisplayUsesLocalOriginAndScale() {
        // 副屏（1x，1920 点宽）位于主屏右侧：CG 全局 x 从 1920 起
        let rect = SelectionGeometry.visiblePixelRect(
            pointsRect: CGRect(x: 2000, y: 100, width: 800, height: 600),
            displayBounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            imageSize: CGSize(width: 1920, height: 1080)
        )
        #expect(rect == CGRect(x: 80, y: 100, width: 800, height: 600))
    }

    @Test func partiallyOffscreenWindowClampsToVisiblePart() {
        // 窗口矩形半出屏：裁到可见部分，不失败
        let rect = SelectionGeometry.visiblePixelRect(
            pointsRect: CGRect(x: 1820, y: 100, width: 200, height: 400),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            imageSize: CGSize(width: 3840, height: 2160)
        )
        #expect(rect == CGRect(x: 3640, y: 200, width: 200, height: 800))
    }

    @Test func disjointSelectionReturnsNil() {
        // 选区与显示器完全不相交 → nil（调用方报"范围无效"）
        let rect = SelectionGeometry.visiblePixelRect(
            pointsRect: CGRect(x: 2500, y: 0, width: 100, height: 100),
            displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            imageSize: CGSize(width: 3840, height: 2160)
        )
        #expect(rect == nil)
    }
}
