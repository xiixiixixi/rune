import Testing
@testable import CaptureKit

@Suite struct ScrollOverlapDetectorTests {
    private let width = 48
    private let height = 120

    // MARK: - 向下

    @Test func detectsRowsAddedAfterScrollingDown() {
        let offset = 27
        let previous = image(startRow: 0)
        let current = image(startRow: offset)
        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result == ScrollMatch(direction: .down, offsetRows: offset, score: result?.score ?? 0))
    }

    @Test func fixedHeaderAndFooterDoNotBreakOverlap() {
        let offset = 31
        var previous = image(startRow: 0)
        var current = image(startRow: offset)
        applyFixedChrome(to: &previous)
        applyFixedChrome(to: &current)

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result?.direction == .down)
        #expect(result?.offsetRows == offset)
    }

    @Test func animatedMiddleBandDoesNotBreakOverlap() {
        let offset = 24
        let previous = image(startRow: 0)
        var current = image(startRow: offset)
        for y in 52..<66 {
            for x in 0..<width {
                current[y * width + x] = UInt8(truncatingIfNeeded: y * 91 + x * 47)
            }
        }

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result?.direction == .down)
        #expect(result?.offsetRows == offset)
    }

    @Test func pageDownSizedScrollStillFindsOverlap() {
        let offset = 108 // 90% 位移，模拟 Page Down / 较快的触控板滚动
        let previous = image(startRow: 0)
        let current = image(startRow: offset)

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result?.direction == .down)
        #expect(result?.offsetRows == offset)
    }

    @Test func preferredOffsetBreaksTiesOnMostlyUniformContent() {
        let offset = 28
        let previous = sparseImage(startRow: 0)
        let current = sparseImage(startRow: offset)

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height,
            preferredOffset: offset
        )
        #expect(result?.direction == .down)
        #expect(result?.offsetRows == offset)
    }

    // MARK: - 向上（聊天记录补历史）

    @Test func detectsRowsAddedBeforeScrollingUp() {
        // previous 显示第 40 行起的内容，向上滚 25 行后 current 显示第 15 行起
        let offset = 25
        let previous = image(startRow: 40)
        let current = image(startRow: 40 - offset)

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result?.direction == .up)
        #expect(result?.offsetRows == offset)
    }

    @Test func pageUpSizedScrollStillFindsOverlap() {
        let offset = 108 // 90% 向上位移
        let previous = image(startRow: offset)
        let current = image(startRow: 0)

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result?.direction == .up)
        #expect(result?.offsetRows == offset)
    }

    @Test func fixedHeaderAndFooterDoNotBreakUpwardOverlap() {
        let offset = 26
        var previous = image(startRow: 60)
        var current = image(startRow: 60 - offset)
        applyFixedChrome(to: &previous)
        applyFixedChrome(to: &current)

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result?.direction == .up)
        #expect(result?.offsetRows == offset)
    }

    // MARK: - 平局与拒绝

    @Test func periodicContentNearTieFollowsPreferredDirection() {
        // 周期 60、平移 30：向下 30 与向上 30 完全并列，方向只能靠先验。
        let previous = periodicImage(period: 60, phase: 0)
        let current = periodicImage(period: 60, phase: 30)

        let downPreferred = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height,
            preferredOffset: 30,
            preferredDirection: .down
        )
        #expect(downPreferred?.direction == .down)
        #expect(downPreferred?.offsetRows == 30)

        let upPreferred = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height,
            preferredOffset: 30,
            preferredDirection: .up
        )
        #expect(upPreferred?.direction == .up)
        #expect(upPreferred?.offsetRows == 30)
    }

    @Test func identicalFramesReportUnchanged() {
        let frame = image(startRow: 10)
        let result = ScrollOverlapDetector.detectScroll(
            previous: frame,
            current: frame,
            width: width,
            height: height
        )
        #expect(result?.offsetRows == 0)
    }

    @Test func tinyLocalAnimationDoesNotLookLikeScrolling() {
        let previous = image(startRow: 0)
        var current = previous
        for y in 54..<57 {
            for x in 0..<width {
                current[y * width + x] = UInt8(truncatingIfNeeded: y * 83 + x * 29)
            }
        }

        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height,
            preferredOffset: 28
        )
        #expect(result?.offsetRows == 0)
    }

    @Test func unrelatedFramesAreRejected() {
        let previous = image(startRow: 0)
        let current = previous.map { 255 &- $0 }
        let result = ScrollOverlapDetector.detectScroll(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result == nil)
    }

    // MARK: - 稳定门

    @Test func isUnchangedToleratesTinyAnimation() {
        let previous = image(startRow: 0)
        var current = previous
        for y in 60..<63 {
            for x in 0..<width {
                current[y * width + x] = UInt8(truncatingIfNeeded: y * 83 + x * 29)
            }
        }
        #expect(ScrollOverlapDetector.isUnchanged(
            previous: previous, current: current, width: width, height: height
        ))
    }

    @Test func isUnchangedRejectsRealMovement() {
        #expect(!ScrollOverlapDetector.isUnchanged(
            previous: image(startRow: 0),
            current: image(startRow: 20),
            width: width,
            height: height
        ))
    }

    // MARK: - 假设位移打分

    @Test func scoreOffsetPrefersTrueDirection() {
        let offset = 24
        let previous = image(startRow: 30)
        let current = image(startRow: 30 - offset)  // 实际向上滚了 24

        let upScore = ScrollOverlapDetector.scoreOffset(
            previous: previous, current: current,
            width: width, height: height,
            offsetRows: offset, direction: .up
        )
        let downScore = ScrollOverlapDetector.scoreOffset(
            previous: previous, current: current,
            width: width, height: height,
            offsetRows: offset, direction: .down
        )
        #expect(upScore != nil && downScore != nil)
        #expect(upScore! < downScore!)
    }

    // MARK: - 构造器

    private func image(startRow: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                UInt8(truncatingIfNeeded: (startRow + y) * 37 + x * 13 + ((startRow + y) * x) % 29)
            }
        }
    }

    private func sparseImage(startRow: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                let globalRow = startRow + y
                guard globalRow.isMultiple(of: 24) || globalRow.isMultiple(of: 37) else {
                    return UInt8(232)
                }
                return UInt8(truncatingIfNeeded: globalRow * 11 + x * 7)
            }
        }
    }

    /// 周期性竖条纹：period 60、平移 30 时向下 30 ≡ 向上 30，制造方向平局。
    private func periodicImage(period: Int, phase: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                UInt8(truncatingIfNeeded: ((y + phase) % period) * 4 + x % 7)
            }
        }
    }

    private func applyFixedChrome(to pixels: inout [UInt8]) {
        for y in 0..<14 {
            for x in 0..<width {
                pixels[y * width + x] = UInt8(truncatingIfNeeded: x * 17 + y * 3)
            }
        }
        for y in (height - 10)..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8(truncatingIfNeeded: 220 - x * 5 + y)
            }
        }
    }
}
