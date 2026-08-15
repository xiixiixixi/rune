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

    private func image(startRow: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                UInt8(truncatingIfNeeded: (startRow + y) * 37 + x * 13 + ((startRow + y) * x) % 29)
            }
        }
    }
}
