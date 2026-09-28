import Testing
@testable import CaptureKit

/// 准周期内容（高度规整的消息卡片流）全链路仿真：
/// detectScroll → ScrollDisplacementResolver → ScrollRangeTracker → ScrollDuplicateGuard。
///
/// 回归背景（2026-09-08 实测）：卡片周期 ≈ 53% 帧高时，"真实位移 ± 周期"
/// 得分完全相同；若给检测器喂上一帧的位移做先验，一次锁错会自我强化，
/// 长图 74% 内容重复、重复间隔恒等于一个周期。此仿真复刻该场景，要求
/// 全链路（手动模式策略：无先验 + 最小位移平局 + 重复闸门）零重复。
@Suite struct ScrollPeriodicSessionSimulationTests {

    private let width = 48
    private let height = 160
    /// 卡片周期：帧高的 56%，与实测事故同量级
    private let period = 90
    private let grayHeight: Int
    private let fullHeight = 2000
    private let grayToFull: Double

    init() {
        // 控制器灰度缩放：宽 192、高按比例；测试图直接用 width×height 灰度行,
        // 全分辨率换算按帧高比例模拟
        grayHeight = height
        grayToFull = Double(fullHeight) / Double(height)
    }

    /// 周期性卡片内容：块状纹理，period 行一循环；blockSeed 让块内纹理有行级变化
    private func contentRow(_ globalRow: Int) -> [UInt8] {
        let phase = ((globalRow % period) + period) % period
        let band = phase / 18   // 每卡片 5 条纹理带
        return (0..<width).map { x in
            UInt8(truncatingIfNeeded: phase * 9 + band * 37 + x * 13)
        }
    }

    private func frame(startRow: Int) -> [UInt8] {
        (0..<height).flatMap { contentRow(startRow + $0) }
    }

    /// 视觉配准的仿真：准周期内容上它会锁到"真实位移 + 一个周期"
    private func visionLockOffset(trueRows: Int) -> Int {
        let trueFull = Int((Double(trueRows) * grayToFull).rounded())
        let periodFull = Int((Double(period) * grayToFull).rounded())
        return trueFull + periodFull
    }

    @Test func manualSessionOnPeriodicContentStitchesWithoutDuplication() {
        let step = 30                       // 每次轮询真实滚动 30 灰度行
        var tracker = ScrollRangeTracker(frameHeight: fullHeight)
        var tailBoundary: [[UInt8]] = []    // 长图尾部的灰度行缓存
        var stitchedRows = 0
        var duplicateRejections = 0

        var previous = frame(startRow: 0)
        tailBoundary = (0..<height).map { contentRow($0) }

        for frameIndex in 1...8 {
            let start = frameIndex * step
            let current = frame(startRow: start)

            // —— 手动模式策略：无先验检测 ——
            let match = ScrollOverlapDetector.detectScroll(
                previous: previous,
                current: current,
                width: width,
                height: height
            )
            // —— 仲裁（配准锁到 true+period） ——
            let vision = visionLockOffset(trueRows: step)
            let visionGrayMagnitude = max(1, Int((Double(abs(vision)) / Double(fullHeight) * Double(height)).rounded()))
            let hypothesis = ScrollOverlapDetector.scoreOffset(
                previous: previous,
                current: current,
                width: width,
                height: height,
                offsetRows: visionGrayMagnitude,
                direction: vision > 0 ? .down : .up
            )
            let resolved = ScrollDisplacementResolver.resolve(
                visionRows: vision,
                grayMatch: match,
                visionHypothesisScore: hypothesis,
                grayHeight: grayHeight,
                fullHeight: fullHeight
            )

            // 真实滚动必然可解
            #expect(resolved != nil)
            guard let resolved, resolved != 0 else { continue }

            // —— 区间跟踪 ——
            let plan = tracker.advance(byRows: resolved)
            guard case .appendBottom(let rows, _) = plan else {
                Issue.record("第 \(frameIndex) 帧应追加底部，实际 \(plan)")
                return
            }
            // —— 重复闸门 ——
            let newRows = (start + height - rows..<start + height).map { contentRow($0) }
            if ScrollDuplicateGuard.isDuplicate(
                newRows: newRows,
                boundaryRows: tailBoundary,
                insertion: .append
            ) {
                duplicateRejections += 1
                continue    // 拦截：锚点不推进
            }
            tailBoundary.append(contentsOf: newRows)
            if tailBoundary.count > 600 { tailBoundary.removeFirst(tailBoundary.count - 600) }
            stitchedRows += rows
            previous = current
        }

        // 8 帧每帧真实新增 step×(full/gray) 全分辨率行，不多不少
        let expectedRows = Int(Double(8 * step) * grayToFull)
        #expect(duplicateRejections == 0)   // 正确仲裁下闸门不应触发
        #expect(abs(stitchedRows - expectedRows) <= 2 * 8)   // 允许取整误差
        #expect(tracker.capturedMax - tracker.capturedMin == fullHeight + stitchedRows)
    }

    @Test func duplicateGuardStopsRunawayAppendEvenIfDisplacementIsWrong() {
        // 即使上游全部失灵、位移恒定高估一个周期，闸门也必须拦住重复条带
        var tracker = ScrollRangeTracker(frameHeight: height)
        let tailBoundary = (0..<height).map { contentRow($0) }
        var rejected = 0
        var stitched = 0

        // 画面真实没动（帧=frame(startRow:0)），但位移被"检测"成一个周期
        let stillFrame = frame(startRow: 0)
        for _ in 0..<5 {
            let plan = tracker.advance(byRows: period)
            guard case .appendBottom(let rows, let frameRows) = plan else {
                Issue.record("应产生追加计划，实际 \(plan)")
                return
            }
            // 高估位移下，"新条带" = 帧底部 rows 行 = 已在尾部缓存中的内容原样复现
            let cropRows = frameRows.map { y in
                Array(stillFrame[(y * width)..<(y * width + width)])
            }
            if ScrollDuplicateGuard.isDuplicate(
                newRows: cropRows,
                boundaryRows: tailBoundary,
                insertion: .append
            ) {
                rejected += 1
                continue
            }
            stitched += rows
        }
        #expect(rejected == 5)   // 每一次都必须被拦截
        #expect(stitched == 0)
    }

    // MARK: - 闸门单元行为

    @Test func guardAcceptsGenuinelyNewContent() {
        let tail = (0..<40).map { y in [UInt8](repeating: UInt8(y * 3 % 200), count: 24) }
        let fresh = (40..<80).map { y in [UInt8](repeating: UInt8(y * 3 % 200), count: 24) }
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: fresh, boundaryRows: tail, insertion: .append
        ))
    }

    @Test func guardRejectsPixelIdenticalStrip() {
        let tail = (0..<40).map { y in [UInt8](repeating: UInt8(y * 5 % 250), count: 24) }
        let repeatStrip = Array(tail.suffix(20))
        #expect(ScrollDuplicateGuard.isDuplicate(
            newRows: repeatStrip, boundaryRows: tail, insertion: .append
        ))
    }

    @Test func guardIgnoresTinyStrips() {
        let tail = (0..<40).map { y in [UInt8](repeating: UInt8(y), count: 24) }
        let tiny = Array(tail.prefix(4))
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: tiny, boundaryRows: tail, insertion: .append
        ))
    }

    @Test func guardRejectsLongPartialOverlapAtBottom() {
        let page = texturedRows(count: 1_400)
        let tail = Array(page[400..<1_000])
        // 实际只新增 140 行，位移却高估为 420：条带前 280 行已在尾部。
        let strip = Array(page[720..<1_140])
        #expect(ScrollDuplicateGuard.isDuplicate(
            newRows: strip, boundaryRows: tail, insertion: .append
        ))
    }

    @Test func guardRejectsLongPartialOverlapAtTop() {
        let page = texturedRows(count: 1_400)
        let head = Array(page[140..<740])
        // 向上补图时，条带后 280 行与已有长图开头重复。
        let strip = Array(page[0..<420])
        #expect(ScrollDuplicateGuard.isDuplicate(
            newRows: strip, boundaryRows: head, insertion: .prepend
        ))
    }

    @Test func guardDoesNotTrustBlankOrShortOverlap() {
        let blank = [UInt8](repeating: 255, count: 24)
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: Array(repeating: blank, count: 420),
            boundaryRows: Array(repeating: blank, count: 600),
            insertion: .append
        ))

        let page = texturedRows(count: 1_400)
        let tail = Array(page[400..<1_000])
        let strip = Array(tail.suffix(32)) + Array(page[1_000..<1_388])
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: strip, boundaryRows: tail, insertion: .append
        ))
    }

    @Test func guardUsesScaledScreenshotRows() {
        // 1000px 高的画面缩成约 192 行；误判 420px ≈ 81 行，
        // 其中 280px 的实际重叠仅 ≈ 54 行。
        let page = texturedRows(count: 300)
        let tail = Array(page[0..<192])
        let appended = Array(page[138..<219])
        #expect(appended.count == 81)
        #expect(ScrollDuplicateGuard.isDuplicate(
            newRows: appended, boundaryRows: tail, insertion: .append
        ))

        let head = Array(page[27..<219])
        let prepended = Array(page[0..<81])
        #expect(ScrollDuplicateGuard.isDuplicate(
            newRows: prepended, boundaryRows: head, insertion: .prepend
        ))

        let blank = [UInt8](repeating: 255, count: 24)
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: Array(repeating: blank, count: 81),
            boundaryRows: Array(repeating: blank, count: 192),
            insertion: .append
        ))
    }

    @Test func guardDoesNotMistakeScaledPeriodicCardsForOverlap() {
        let cards = (0..<300).map { row in
            (0..<24).map { column in
                UInt8(truncatingIfNeeded: (row % 20) * 37 + column * 13 + (row % 20) * column * 7)
            }
        }
        // 新内容有明显纹理，但每 20 行复现一次；多个长度都能对齐。
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: Array(cards[192..<273]),
            boundaryRows: Array(cards[0..<192]),
            insertion: .append
        ))
    }

    @Test func guardDoesNotRejectAnExactlyPeriodicNewCard() {
        let period = 20
        func row(_ index: Int) -> [UInt8] {
            (0..<24).map { column in
                UInt8(truncatingIfNeeded: (index % period) * 17 + column * 23)
            }
        }
        let boundary = (0..<192).map(row)
        let genuinelyNew = (192..<272).map(row)
        #expect(!ScrollDuplicateGuard.isDuplicate(
            newRows: genuinelyNew,
            boundaryRows: boundary,
            insertion: .append
        ))
    }

    private func texturedRows(count: Int) -> [[UInt8]] {
        (0..<count).map { row in
            (0..<24).map { column in
                UInt8(truncatingIfNeeded:
                    (row * 73 + column * 31 + row * column * 17 + (row / 97) * 59)
                        ^ ((row / 256) * 137)
                )
            }
        }
    }
}
