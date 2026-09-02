import Testing
@testable import CaptureKit

@Suite struct ScrollOverlapDetectorTests {
    private let width = 48
    private let height = 120

    @Test func detectsRowsAddedAfterScrollingDown() {
        let offset = 27
        let previous = image(startRow: 0)
        let current = image(startRow: offset)
        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result == offset)
    }

    @Test func identicalFramesAppendNothing() {
        let frame = image(startRow: 10)
        let result = ScrollOverlapDetector.appendedRowCount(
            previous: frame,
            current: frame,
            width: width,
            height: height
        )
        #expect(result == 0)
    }

    @Test func unrelatedFramesAreRejected() {
        let previous = image(startRow: 0)
        let current = previous.map { 255 &- $0 }
        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result == nil)
    }

    @Test func fixedHeaderAndFooterDoNotBreakOverlap() {
        let offset = 31
        var previous = image(startRow: 0)
        var current = image(startRow: offset)
        applyFixedChrome(to: &previous)
        applyFixedChrome(to: &current)

        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result == offset)
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

        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height
        )
        #expect(result == offset)
    }

    @Test func tinyLocalAnimationDoesNotLookLikeScrolling() {
        let previous = image(startRow: 0)
        var current = previous
        for y in 54..<57 {
            for x in 0..<width {
                current[y * width + x] = UInt8(truncatingIfNeeded: y * 83 + x * 29)
            }
        }

        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height,
            preferredOffset: 28
        )

        #expect(result == 0)
    }

    @Test func pageDownSizedScrollStillFindsOverlap() {
        let offset = 108 // 90% 位移，模拟 Page Down / 较快的触控板滚动
        let previous = image(startRow: 0)
        let current = image(startRow: offset)

        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height
        )

        #expect(result == offset)
    }

    @Test func preferredOffsetBreaksTiesOnMostlyUniformContent() {
        let offset = 28
        let previous = sparseImage(startRow: 0)
        let current = sparseImage(startRow: offset)

        let result = ScrollOverlapDetector.appendedRowCount(
            previous: previous,
            current: current,
            width: width,
            height: height,
            preferredOffset: offset
        )

        #expect(result == offset)
    }

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
