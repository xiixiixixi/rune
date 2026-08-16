import CoreGraphics
import Testing
@testable import CaptureKit

/// 坐标换算测试：主屏、左侧屏、Retina 缩放、跨屏交集与拼接画布。
/// 依据 M1 设计文档 §3.3（纯函数可测）与 §6 测试清单。
@Suite struct DisplayLayoutTests {

    // 主屏 Retina：1920×1080 pt @2x
    private let mainRetina = DisplayDescriptor(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), backingScaleFactor: 2)
    // 左侧非 Retina 副屏：1440×900 pt @1x，位于主屏左侧
    private let leftNonRetina = DisplayDescriptor(
        id: 2, frame: CGRect(x: -1440, y: 0, width: 1440, height: 900), backingScaleFactor: 1)

    @Test func pixelFrameOfRetinaDisplay() {
        let frame = DisplayLayout.pixelFrame(of: mainRetina)
        #expect(frame == CGRect(x: 0, y: 0, width: 3840, height: 2160))
    }

    @Test func pixelFrameOfNonRetinaDisplay() {
        let frame = DisplayLayout.pixelFrame(of: leftNonRetina)
        #expect(frame == CGRect(x: 0, y: 0, width: 1440, height: 900))
    }

    @Test func pixelRectOnRetinaDisplayAtBottom() {
        // 全局点空间矩形贴屏幕底部（y: 0→50）→ 左上原点像素空间应在底部 100px 处
        let rect = DisplayLayout.pixelRect(in: mainRetina, for: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(rect == CGRect(x: 0, y: 2060, width: 200, height: 100))
    }

    @Test func pixelRectOnRetinaDisplayAtTop() {
        // 全局点空间矩形贴屏幕顶部（y: 1030→1080）→ 左上原点像素空间在 y=0
        let rect = DisplayLayout.pixelRect(in: mainRetina, for: CGRect(x: 0, y: 1030, width: 100, height: 50))
        #expect(rect == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func pixelRectOnLeftDisplayRightEdge() {
        // 左屏右半部：全局点 x -720→0 → 局部像素 x 720→1440
        let rect = DisplayLayout.pixelRect(in: leftNonRetina, for: CGRect(x: -720, y: 0, width: 720, height: 900))
        #expect(rect == CGRect(x: 720, y: 0, width: 720, height: 900))
    }

    @Test func layoutBoundsSpansBothDisplays() {
        let bounds = DisplayLayout.layoutBounds(of: [mainRetina, leftNonRetina])
        #expect(bounds == CGRect(x: -1440, y: 0, width: 3360, height: 1080))
    }

    @Test func canvasLayoutUnifiedScale() {
        let (canvasSize, frames) = DisplayLayout.canvasLayout(displays: [mainRetina, leftNonRetina])
        // 统一倍率 2x：画布 = 点布局 × 2
        #expect(canvasSize == CGSize(width: 6720, height: 2160))
        let framesByID = Dictionary(uniqueKeysWithValues: frames.map { ($0.displayID, $0.pixelFrame) })
        // 左屏（1x）在画布中：x=0，y 从顶部 360 开始（左屏矮 180pt）
        #expect(framesByID[leftNonRetina.id] == CGRect(x: 0, y: 360, width: 2880, height: 1800))
        // 主屏（2x）在画布中：x=2880（右半），y=0（与布局顶部对齐）
        #expect(framesByID[mainRetina.id] == CGRect(x: 2880, y: 0, width: 3840, height: 2160))
    }

    @Test func crossDisplaySelectionCollectsBothScreensPrimaryFirst() {
        // 选区横跨两屏：x -720→720，y 100→700（点空间）
        let selection = CGRect(x: -720, y: 100, width: 1440, height: 600)
        let rects = DisplayLayout.pixelRects(
            for: selection,
            displays: [mainRetina, leftNonRetina],
            primaryID: mainRetina.id
        )
        #expect(rects.count == 2)
        // 主屏优先
        #expect(rects[0].displayID == mainRetina.id)
        #expect(rects[1].displayID == leftNonRetina.id)
        // 主屏段：画布坐标 x=2880，y=(1080-700)*2=760，尺寸 720×600pt → 1440×1200px
        #expect(rects[0].pixelRect == CGRect(x: 2880, y: 760, width: 1440, height: 1200))
        // 左屏段：画布坐标 x=1440，y=760，同样 1440×1200px
        #expect(rects[1].pixelRect == CGRect(x: 1440, y: 760, width: 1440, height: 1200))
    }

    @Test func selectionContainedInOneDisplayCollectsSingleRect() {
        let selection = CGRect(x: 100, y: 100, width: 400, height: 300)
        let rects = DisplayLayout.pixelRects(
            for: selection,
            displays: [mainRetina, leftNonRetina],
            primaryID: mainRetina.id
        )
        #expect(rects.count == 1)
        #expect(rects[0].displayID == mainRetina.id)
        #expect(rects[0].pixelRect == CGRect(x: 3080, y: 1360, width: 800, height: 600))
    }

    @Test func nonIntersectingSelectionCollectsNothing() {
        // 选区完全在两屏之外（上方空白区域）
        let selection = CGRect(x: 0, y: 2000, width: 100, height: 100)
        let rects = DisplayLayout.pixelRects(
            for: selection,
            displays: [mainRetina, leftNonRetina],
            primaryID: mainRetina.id
        )
        #expect(rects.isEmpty)
    }
}
