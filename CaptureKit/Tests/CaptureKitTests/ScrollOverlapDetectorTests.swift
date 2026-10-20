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

    @Test func maximumOffsetKeepsPeriodicAliasOutsideAutomaticScrollRange() {
        // 稀疏卡片每 60 行重复，实际只滚 20 行；20 和 80 行都能对上。
        // 旧步长若恰好接近 80，软先验会偏向远处的重复卡片。
        let previous = sparsePeriodicImage(period: 60, phase: 0)
        let current = sparsePeriodicImage(period: 60, phase: 20)
        let unrestricted = ScrollOverlapDetector.detectScroll(
            previous: previous, current: current,
            width: width, height: height,
            preferredOffset: 80, preferredDirection: .down
        )
        #expect(unrestricted?.offsetRows == 80)

        let bounded = ScrollOverlapDetector.detectScroll(
            previous: previous, current: current,
            width: width, height: height,
            preferredOffset: 80, preferredDirection: .down,
            maximumOffset: 30
        )
        #expect(bounded?.direction == .down)
        #expect(bounded?.offsetRows == 20)
    }

    @Test func maximumOffsetRejectsFramesWithoutPlausibleOverlap() {
        let previous = image(startRow: 0)
        let current = image(startRow: 78)
        let unrestricted = ScrollOverlapDetector.detectScroll(
            previous: previous, current: current,
            width: width, height: height
        )
        #expect(unrestricted?.offsetRows == 78)

        let bounded = ScrollOverlapDetector.detectScroll(
            previous: previous, current: current,
            width: width, height: height,
            preferredOffset: 78, preferredDirection: .down,
            maximumOffset: 25
        )
        #expect(bounded == nil)
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

    private func sparsePeriodicImage(period: Int, phase: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                let cardRow = (y + phase) % period
                return cardRow < 4
                    ? UInt8(truncatingIfNeeded: cardRow * 41 + x * 17)
                    : UInt8(236)
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
    // MARK: - 长图尾部锚定（失配自愈）

    @Test func tailAnchorLocatesContinuingFrame() {
        // 长图尾部 0..300；上一锚帧占 180..300，当前帧从 245 继续向下。
        let tail = tallImage(rows: 300)
        let previous = frameImage(startRow: 180)
        let current = frameImage(startRow: 245)

        let previousAnchor = ScrollOverlapDetector.detectTailAnchor(
            tail: tail, tailHeight: 300,
            current: previous, width: width, height: height,
            minimumOverlap: 16
        )
        let currentAnchor = ScrollOverlapDetector.detectTailAnchor(
            tail: tail, tailHeight: 300,
            current: current, width: width, height: height,
            minimumOverlap: 16
        )

        #expect(previousAnchor?.anchorRow == 180)
        #expect(currentAnchor?.anchorRow == 245)
        // 两锚点之差就是恢复出的位移（灰度行）
        #expect((currentAnchor?.anchorRow ?? 0) - (previousAnchor?.anchorRow ?? 0) == 65)
    }

    @Test func tailAnchorRejectsFrameBeyondTail() {
        // 当前帧顶行已越过长图末尾（漏了一段内容），重叠不足必须拒绝。
        let tail = tallImage(rows: 300)
        let current = frameImage(startRow: 300)
        let result = ScrollOverlapDetector.detectTailAnchor(
            tail: tail, tailHeight: 300,
            current: current, width: width, height: height,
            minimumOverlap: 16
        )
        #expect(result == nil)
    }

    @Test func tailAnchorRejectsUnrelatedFrame() {
        // 与长图毫无关系的帧（内容错位 + 灰度翻转）不得被错接。
        let tail = tallImage(rows: 300)
        let current = frameImage(startRow: 80).map { ~$0 }
        let result = ScrollOverlapDetector.detectTailAnchor(
            tail: tail, tailHeight: 300,
            current: current, width: width, height: height,
            minimumOverlap: 16
        )
        #expect(result == nil)
    }

    @Test func tailAnchorRejectsAmbiguousPeriodicTail() {
        // 尾部为周期内容时远处会出现同分假锚点，必须因歧义而放弃。
        let tail = periodicTallImage(period: 12, rows: 300)
        let current = periodicFrameImage(period: 12, phase: 180)
        let result = ScrollOverlapDetector.detectTailAnchor(
            tail: tail, tailHeight: 300,
            current: current, width: width, height: height,
            minimumOverlap: 16
        )
        #expect(result == nil)
    }

    @Test func tailAnchorRequiresMinimumOverlap() {
        // 重叠低于 minimumOverlap 的锚点不存在（尾部只剩 10 行可用）。
        let tail = tallImage(rows: 40)
        let current = frameImage(startRow: 34)
        let result = ScrollOverlapDetector.detectTailAnchor(
            tail: tail, tailHeight: 40,
            current: current, width: width, height: height,
            minimumOverlap: 16
        )
        #expect(result == nil)
    }

    /// 行哈希（splitmix 常数）避免合成内容以 256 行周期自重复——
    /// 否则远处行会逐字节相同，制造出算法必须拒绝的假锚点。
    private func hashedRow(_ row: Int) -> UInt8 {
        // splitmix64 终结器：乘 golden 常数后再三轮 xorshift 搅拌，
        // 消除小行号下"近似线性"导致的行间近碰撞。
        var x: UInt64 = UInt64(bitPattern: Int64(row)) &+ 0x9E3779B97F4A7C15
        x ^= x >> 30
        x &*= 0xBF58476D1CE4E5B9
        x ^= x >> 27
        x &*= 0x94D049BB133111EB
        x ^= x >> 31
        return UInt8(truncatingIfNeeded: x >> 56)
    }

    private func syntheticPixel(row: Int, column: Int) -> UInt8 {
        let base: Int = Int(hashedRow(row))
        let mix: Int = (row + column) % 7
        return UInt8(truncatingIfNeeded: base + column * 13 + mix)
    }

    private func frameImage(startRow: Int) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels.append(syntheticPixel(row: startRow + y, column: x))
            }
        }
        return pixels
    }

    private func tallImage(rows: Int) -> [UInt8] {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * rows)
        for y in 0..<rows {
            for x in 0..<width {
                pixels.append(syntheticPixel(row: y, column: x))
            }
        }
        return pixels
    }

    private func periodicTallImage(period: Int, rows: Int) -> [UInt8] {
        (0..<rows).flatMap { y in
            (0..<width).map { x in
                UInt8(truncatingIfNeeded: (y % period) * 53 + x * 11)
            }
        }
    }

    private func periodicFrameImage(period: Int, phase: Int) -> [UInt8] {
        (0..<height).flatMap { y in
            (0..<width).map { x in
                UInt8(truncatingIfNeeded: ((phase + y) % period) * 53 + x * 11)
            }
        }
    }
}
