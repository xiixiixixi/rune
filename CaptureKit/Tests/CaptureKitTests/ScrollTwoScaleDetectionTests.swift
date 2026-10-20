import Testing
@testable import CaptureKit

/// 粗→细两级重叠检测（对应 VESDK 的多尺度金字塔搜索）。
///
/// 真实事故场景：画面被缩到固定宽度后，位移的量化误差是"捕获宽 ÷ 缩略图宽"。
/// 捕获 900 像素宽、缩略图 192 像素宽时，一次接缝的误差可达 2–3 像素。
/// 更糟的是：真实滚动距离几乎不可能正好是缩略图行比的整数倍，粗缩略图
/// 的重叠区因此永远对不齐，**单尺度检测会直接判不出重叠**。
@Suite struct ScrollTwoScaleDetectionTests {

    /// 细尺度页面：96 宽（真实场景约 480），内容不重复——否则任何周期倍数
    /// 都是"完美匹配"，位移本身就无从分辨。
    private let fineWidth = 96
    private let frameRows = 600

    private func pageRow(_ index: Int) -> [UInt8] {
        (0..<fineWidth).map { x in
            UInt8(truncatingIfNeeded:
                (index &* 73 &+ x &* 31 &+ index &* x &* 17 &+ (index / 97) &* 59)
                    ^ ((index / 256) &* 137)
            )
        }
    }

    /// 粗尺度：每隔一行、每隔一列采样一次（相当于缩到一半）。
    private func coarseFrame(startRow: Int) -> ScrollGrayFrame {
        var pixels: [UInt8] = []
        var row = startRow
        while row < startRow + frameRows {
            var x = 0
            while x < fineWidth {
                pixels.append(pageRow(row)[x])
                x += 2
            }
            row += 2
        }
        let width = (fineWidth + 1) / 2
        return ScrollGrayFrame(pixels: pixels, width: width, height: pixels.count / width)
    }

    private func fineFrame(startRow: Int) -> ScrollGrayFrame {
        var pixels: [UInt8] = []
        for row in startRow..<(startRow + frameRows) {
            pixels.append(contentsOf: pageRow(row))
        }
        return ScrollGrayFrame(pixels: pixels, width: fineWidth, height: frameRows)
    }

    @Test func twoScaleRescuesCasesWhereSingleScaleFindsNoOverlap() {
        // 位移不是粗尺度行比整数倍时，粗缩略图的重叠永远对不齐 → 单尺度判不出重叠
        for displacement in [37, 137, 259] {
            let coarsePrevious = coarseFrame(startRow: 0)
            let coarseCurrent = coarseFrame(startRow: displacement)
            let finePrevious = fineFrame(startRow: 0)
            let fineCurrent = fineFrame(startRow: displacement)

            let coarseOnly = ScrollOverlapDetector.detectScroll(
                previous: coarsePrevious.pixels,
                current: coarseCurrent.pixels,
                width: coarsePrevious.width,
                height: coarsePrevious.height
            )
            #expect(coarseOnly == nil, "位移 \(displacement) 的粗尺度本应对不齐")

            let twoScale = ScrollOverlapDetector.detectScrollTwoScale(
                coarsePrevious: coarsePrevious,
                coarseCurrent: coarseCurrent,
                finePrevious: finePrevious,
                fineCurrent: fineCurrent
            )
            #expect(twoScale != nil, "两级检测应救回位移 \(displacement)")
            #expect(twoScale?.offsetRows == displacement, "两级检测应精确命中位移 \(displacement)")
        }
    }

    @Test func twoScaleKeepsCoarseAnswerWhenItIsAlreadyAligned() {
        // 位移正好是粗尺度行比的整数倍时，两级结果应当一致
        let displacement = 470
        let coarsePrevious = coarseFrame(startRow: 0)
        let coarseCurrent = coarseFrame(startRow: displacement)
        let finePrevious = fineFrame(startRow: 0)
        let fineCurrent = fineFrame(startRow: displacement)

        let coarseOnly = ScrollOverlapDetector.detectScroll(
            previous: coarsePrevious.pixels,
            current: coarseCurrent.pixels,
            width: coarsePrevious.width,
            height: coarsePrevious.height
        )
        #expect(coarseOnly != nil)

        let twoScale = ScrollOverlapDetector.detectScrollTwoScale(
            coarsePrevious: coarsePrevious,
            coarseCurrent: coarseCurrent,
            finePrevious: finePrevious,
            fineCurrent: fineCurrent
        )
        #expect(twoScale?.offsetRows == displacement)
    }
}

/// 长图尾部重锚的行向量口径。
///
/// 尾部缓存是"每行 24 个采样"的行向量。像素版锚定要求尾部是原始像素行，
/// 两者混用会让长度校验直接失败——生产链路里这条自愈路径曾因此静默失效。
@Suite struct ScrollTailAnchorVectorTests {

    /// 内容必须唯一：周期性内容会让任意周期倍数都"完美匹配"，锚点无从分辨。
    private func pageRow(_ index: Int, salt: Int) -> [UInt8] {
        (0..<24).map { column in
            UInt8(truncatingIfNeeded:
                ((index &* 73 &+ column &* 31 &+ index &* column &* 17 &+ salt) % 251)
                    ^ ((index / 32) &* 137)
            )
        }
    }

    private func rows(_ range: Range<Int>, salt: Int) -> [[UInt8]] {
        range.map { pageRow($0, salt: salt) }
    }

    @Test func vectorAnchorFindsTheKnownOffset() {
        // 长图尾部 = 内容 [200, 400)；上一锚帧 = [300, 400)（锚点 100）；
        // 当前帧又往下滚了 40 行 = [340, 440)（锚点 140）。
        let tail = rows(200..<400, salt: 0)
        let previous = rows(300..<400, salt: 0)
        let current = rows(340..<440, salt: 0)

        let previousAnchor = ScrollOverlapDetector.detectTailAnchor(
            tailRows: tail, currentRows: previous, minimumOverlap: 16
        )
        let currentAnchor = ScrollOverlapDetector.detectTailAnchor(
            tailRows: tail, currentRows: current, minimumOverlap: 16
        )
        #expect(previousAnchor?.anchorRow == 100)
        #expect(currentAnchor?.anchorRow == 140)
    }

    @Test func vectorAnchorRejectsUnrelatedContent() {
        let tail = rows(200..<400, salt: 0)
        let unrelated = rows(300..<400, salt: 77)
        let anchor = ScrollOverlapDetector.detectTailAnchor(
            tailRows: tail,
            currentRows: unrelated,
            minimumOverlap: 16
        )
        #expect(anchor == nil)
    }

    @Test func rowVectorSamplerMatchesDocumentedLayout() {
        let width = 100
        let height = 4
        let pixels = (0..<(width * height)).map { UInt8($0 % 256) }
        let vectors = ScrollOverlapDetector.rowVectors(
            pixels: pixels, width: width, height: height
        )
        #expect(vectors.count == height)
        #expect(vectors.first?.count == 24)
        #expect(vectors[0][0] == 0)
        #expect(vectors[0][1] == pixels[4])   // 100 / 24 = 4 的取整
    }
}
