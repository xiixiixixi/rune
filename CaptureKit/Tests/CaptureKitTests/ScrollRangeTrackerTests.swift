import Testing
@testable import CaptureKit

/// 区间跟踪器：双向拼接 + 回退不重复——聊天记录“向下翻、向上补、再向下”的核心路径。
@Suite struct ScrollRangeTrackerTests {
    private let frameHeight = 100

    @Test func firstScrollDownAppendsBottomRows() {
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        let plan = tracker.advance(byRows: 40)
        guard case .appendBottom(let rows, let frameRows) = plan else {
            Issue.record("期望 appendBottom，实际 \(plan)")
            return
        }
        #expect(rows == 40)
        // 新内容在当前帧最底部 40 行
        #expect(frameRows == 60..<100)
        #expect(tracker.capturedMin == 0)
        #expect(tracker.capturedMax == 140)
    }

    @Test func scrollUpPrependsTopRows() {
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        _ = tracker.advance(byRows: 50)          // 覆盖 [0, 150]
        let plan = tracker.advance(byRows: -30)  // 起点回到 20，仍在区间内？
        // 20 > 0 → 没有新内容
        #expect(plan == .rollback)

        let plan2 = tracker.advance(byRows: -60) // 起点到 -40，高于区间顶
        guard case .prependTop(let rows, let frameRows) = plan2 else {
            Issue.record("期望 prependTop，实际 \(plan2)")
            return
        }
        #expect(rows == 40)
        #expect(frameRows == 0..<40)
        #expect(tracker.capturedMin == -40)
        #expect(tracker.capturedMax == 150)
    }

    @Test func pureUpwardSessionPrependsFromStart() {
        // 用户直接从对话中部向上翻历史
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        let plan = tracker.advance(byRows: -40)
        guard case .prependTop(let rows, let frameRows) = plan else {
            Issue.record("期望 prependTop，实际 \(plan)")
            return
        }
        #expect(rows == 40)
        #expect(frameRows == 0..<40)
        #expect(tracker.capturedMin == -40)
        #expect(tracker.capturedMax == 100)
    }

    @Test func downUpDownSequenceNeverDuplicates() {
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        // 向下 50 → [0, 150]
        guard case .appendBottom(let first, _) = tracker.advance(byRows: 50) else {
            fatalError("第一步应为 appendBottom")
        }
        #expect(first == 50)

        // 向上 80 → 起点 -30，顶部新内容 30 行（底部无新增）
        guard case .prependTop(let up, _) = tracker.advance(byRows: -80) else {
            fatalError("第二步应为 prependTop")
        }
        #expect(up == 30)
        #expect(tracker.capturedMin == -30)

        // 再向下 90 → 起点 60，终点 160 > 150：只追加 [150, 160) 共 10 行，
        // [60, 150) 是回看已捕获内容，不得重复拼接
        guard case .appendBottom(let third, let frameRows) = tracker.advance(byRows: 90) else {
            fatalError("第三步应为 appendBottom")
        }
        #expect(third == 10)
        #expect(frameRows == 90..<100)
        #expect(tracker.capturedMin == -30)
        #expect(tracker.capturedMax == 160)
    }

    @Test func rollbackWithinCapturedRangeAddsNothing() {
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        _ = tracker.advance(byRows: 60)   // 覆盖 [0, 160]，锚点 60
        #expect(tracker.advance(byRows: -20) == .rollback)  // 锚点 40
        #expect(tracker.advance(byRows: 10) == .rollback)   // 锚点 50
        // 回看后再向下 60：起点 110，终点 210 > 160 → 只追加 [160, 210) 共 50 行
        guard case .appendBottom(let rows, let frameRows) = tracker.advance(byRows: 60) else {
            fatalError("应为 appendBottom")
        }
        #expect(rows == 50)
        #expect(frameRows == 50..<100)
        #expect(tracker.capturedMax == 210)
    }

    @Test func zeroDisplacementIsUnchanged() {
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        #expect(tracker.advance(byRows: 0) == .unchanged)
    }

    @Test func fullFrameDisplacementLosesOverlap() {
        var tracker = ScrollRangeTracker(frameHeight: frameHeight)
        #expect(tracker.advance(byRows: frameHeight) == .lostOverlap)
        #expect(tracker.advance(byRows: -frameHeight) == .lostOverlap)
        #expect(tracker.advance(byRows: frameHeight + 20) == .lostOverlap)
    }
}
