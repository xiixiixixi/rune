import Testing
@testable import CaptureKit

@Suite struct ScrollFixedBandDetectorTests {
    private let width = 96
    private let height = 100

    @Test func findsTexturedHeaderAndFooterBesideMovingContent() {
        var previous = page(startRow: 0)
        var current = page(startRow: 13)
        putFixedBand(in: &previous, rows: 0..<11)
        putFixedBand(in: &current, rows: 0..<11)
        putFixedBand(in: &previous, rows: 92..<100)
        putFixedBand(in: &current, rows: 92..<100)

        #expect(detect(previous, current) == ScrollFixedBands(topRows: 11, bottomRows: 8))
    }

    @Test func plainWhiteMarginsAreNotFixedBars() {
        var previous = page(startRow: 0)
        var current = page(startRow: 13)
        putPlainBand(in: &previous, rows: 0..<10)
        putPlainBand(in: &current, rows: 0..<10)
        putPlainBand(in: &previous, rows: 91..<100)
        putPlainBand(in: &current, rows: 91..<100)

        #expect(detect(previous, current) == ScrollFixedBands(topRows: 0, bottomRows: 0))
    }

    @Test func findsLowContrastFooterAtScreenshotScale() {
        let width = 192
        let height = 122
        func page(_ start: Int) -> [UInt8] {
            (0..<height).flatMap { y in
                (0..<width).map { x in
                    UInt8((13 * (start + y) + 19 * (x / 5) + 71) % 256)
                }
            }
        }
        var previous = page(0)
        var current = page(19)
        for y in 116..<height {
            for x in 0..<width {
                // 缩小后的浅灰栏仅有少数 15 级对比度的文字笔画。
                let ink = (118...120).contains(y) && (x / 7).isMultiple(of: 3)
                let value: UInt8 = ink ? 252 : 237
                previous[y * width + x] = value
                current[y * width + x] = value
            }
        }
        #expect(ScrollFixedBandDetector.detect(
            previous: previous, current: current, width: width, height: height
        ).bottomRows == 6)
    }

    @Test func periodicCardsShiftedOnePeriodDoNotLookLikeBars() {
        let previous = periodicPage(startRow: 0, period: 19)
        let current = periodicPage(startRow: 19, period: 19)

        #expect(previous == current)
        #expect(detect(previous, current) == ScrollFixedBands(topRows: 0, bottomRows: 0))
    }

    @Test func unchangedPageAndLocalAnimationAreNotScrolling() {
        let previous = page(startRow: 0)
        var current = previous
        #expect(detect(previous, current) == ScrollFixedBands(topRows: 0, bottomRows: 0))

        // 局部动态图只改变正文中间；边缘虽然静止，却没有紧邻的滚动证据。
        for y in 45..<55 {
            for x in 30..<50 {
                current[y * width + x] = 255 &- current[y * width + x]
            }
        }
        #expect(detect(previous, current) == ScrollFixedBands(topRows: 0, bottomRows: 0))
    }

    @Test func stationarySidebarBesideScrollingPageIsNotHorizontalBar() {
        var previous = page(startRow: 0)
        var current = page(startRow: 13)
        for y in 0..<height {
            for x in 0..<24 {
                let value = UInt8((x * 17 + y * 11) % 256)
                previous[y * width + x] = value
                current[y * width + x] = value
            }
        }

        #expect(detect(previous, current) == ScrollFixedBands(topRows: 0, bottomRows: 0))
    }

    @Test func changingSidebarInvalidatesOtherwiseStaticHeader() {
        var previous = page(startRow: 0)
        var current = page(startRow: 13)
        putFixedBand(in: &previous, rows: 0..<11)
        putFixedBand(in: &current, rows: 0..<11)
        for y in 0..<11 {
            for x in 80..<width {
                current[y * width + x] = 255 &- current[y * width + x]
            }
        }

        #expect(detect(previous, current).topRows == 0)
    }

    private func detect(_ previous: [UInt8], _ current: [UInt8]) -> ScrollFixedBands {
        ScrollFixedBandDetector.detect(
            previous: previous, current: current, width: width, height: height
        )
    }

    private func page(startRow: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                UInt8((13 * (startRow + y) + 27 * (x / 3) + x + 41) % 256)
            }
        }
    }

    private func periodicPage(startRow: Int, period: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                UInt8((17 * ((startRow + y) % period) + 31 * (x / 4)) % 256)
            }
        }
    }

    private func putFixedBand(in pixels: inout [UInt8], rows: Range<Int>) {
        for y in rows {
            for x in 0..<width {
                pixels[y * width + x] = (x / 6 + y / 3).isMultiple(of: 2) ? 35 : 220
            }
        }
    }

    private func putPlainBand(in pixels: inout [UInt8], rows: Range<Int>) {
        for y in rows {
            for x in 0..<width {
                pixels[y * width + x] = 250
            }
        }
    }
}
