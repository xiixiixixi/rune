import Testing
@testable import CaptureKit

/// 位移仲裁:投票为主、配准为辅。回归场景——配准被重复卡片锁到
/// “真实位移+周期”时必须信投票,否则长图大面积重复。
@Suite struct ScrollDisplacementResolverTests {
    private let grayHeight = 100
    private let fullHeight = 500

    @Test func agreeingVotesRefineToVisionValue() {
        // 投票 140 全分辨率行,配准 146(同向,差在容差内)→ 用配准精化
        let gray = ScrollMatch(direction: .down, offsetRows: 28, score: 3)
        let resolved = ScrollDisplacementResolver.resolve(
            visionRows: 146,
            grayMatch: gray,
            visionHypothesisScore: 3,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        )
        #expect(resolved == 146)
    }

    @Test func visionLockedToCardPeriodFallsBackToVote() {
        // 回归主场景:真实滚了 140,配准锁到 140+周期 380 = 520;
        // 投票给出 140 → 必须信投票,不信配准
        let gray = ScrollMatch(direction: .down, offsetRows: 28, score: 4)
        let resolved = ScrollDisplacementResolver.resolve(
            visionRows: 520,
            grayMatch: gray,
            visionHypothesisScore: 26,   // 假设位移在灰度下对不上
            grayHeight: grayHeight,
            fullHeight: fullHeight
        )
        #expect(resolved == 140)
    }

    @Test func visionOnlyAcceptedWithVerifiedHypothesis() {
        // 投票无重叠(选区内容太稀),配准假设通过灰度验证 → 接受配准
        let resolved = ScrollDisplacementResolver.resolve(
            visionRows: -90,
            grayMatch: nil,
            visionHypothesisScore: 6,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        )
        #expect(resolved == -90)
    }

    @Test func visionOnlyWithoutVerificationIsRejected() {
        let resolved = ScrollDisplacementResolver.resolve(
            visionRows: 400,
            grayMatch: nil,
            visionHypothesisScore: 30,   // 灰度对不上这个假设
            grayHeight: grayHeight,
            fullHeight: fullHeight
        )
        #expect(resolved == nil)
    }

    @Test func grayUnchangedOverruledOnlyByNearPerfectVision() {
        // 投影判未变,配准 1 行以内 = 噪声 → 按未变处理
        let unchanged = ScrollMatch(direction: .down, offsetRows: 0, score: 0)
        #expect(ScrollDisplacementResolver.resolve(
            visionRows: 1,
            grayMatch: unchanged,
            visionHypothesisScore: 2,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        ) == 0)

        // 投票判未变,但配准的假设施加近乎完美(如微小平移被投票量化吃掉)
        #expect(ScrollDisplacementResolver.resolve(
            visionRows: 8,
            grayMatch: unchanged,
            visionHypothesisScore: 3,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        ) == 8)

        // 投票判未变 + 配准声称大位移但灰度不支持 → 维持未变
        #expect(ScrollDisplacementResolver.resolve(
            visionRows: 120,
            grayMatch: unchanged,
            visionHypothesisScore: 25,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        ) == 0)
    }

    @Test func upwardVoteProducesNegativeDisplacement() {
        let gray = ScrollMatch(direction: .up, offsetRows: 20, score: 3)
        let resolved = ScrollDisplacementResolver.resolve(
            visionRows: nil,
            grayMatch: gray,
            visionHypothesisScore: nil,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        )
        #expect(resolved == -100)
    }

    @Test func excessiveJumpIsUntrusted() {
        // 单帧位移超过 0.9 帧高:正常小步滚不出来,按不可信处理
        let gray = ScrollMatch(direction: .down, offsetRows: 96, score: 2)  // → 480 全分辨率
        #expect(ScrollDisplacementResolver.resolve(
            visionRows: nil,
            grayMatch: gray,
            visionHypothesisScore: nil,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        ) == nil)

        // 投票无重叠 + 配准超大位移也拒
        #expect(ScrollDisplacementResolver.resolve(
            visionRows: 490,
            grayMatch: nil,
            visionHypothesisScore: 4,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        ) == nil)
    }

    @Test func noEvidenceAtAllIsUntrusted() {
        #expect(ScrollDisplacementResolver.resolve(
            visionRows: nil,
            grayMatch: nil,
            visionHypothesisScore: nil,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        ) == nil)
    }

    @Test func visionAgreesOnDirectionButNotMagnitudeTrustsVote() {
        // 同向但量级差太远(周期锁定特征)→ 投票为准
        let gray = ScrollMatch(direction: .down, offsetRows: 30, score: 3)  // → 150
        let resolved = ScrollDisplacementResolver.resolve(
            visionRows: 420,
            grayMatch: gray,
            visionHypothesisScore: 20,
            grayHeight: grayHeight,
            fullHeight: fullHeight
        )
        #expect(resolved == 150)
    }
}
