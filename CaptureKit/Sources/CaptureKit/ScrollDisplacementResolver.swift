/// 相邻帧位移的最终仲裁（纯逻辑）。
///
/// 两个证据源各有强弱：
/// - Vision 图像配准：亚像素精度，但在周期性/重复卡片内容上会把
///   “真实位移 + 整数个周期”当成最佳对齐，位移被系统性高估——
///   拼出来的长图会出现大面积重复段（实测一帧高估即可毁掉整张长图）。
/// - 灰度五分区投票：对周期锁相不敏感（各带独立找最优 + 共识门），
///   但量化到缩略图行，精度有限。
///
/// 因此仲裁规则是**投票为主、配准为辅**：
/// 1. 投票给出位移 → 配准同向且量级一致时用配准值精化，否则信投票；
/// 2. 投票判“未变” → 配准声称移动时必须有近乎完美的灰度支持才放行；
/// 3. 投票无重叠 → 配准单独立场需通过假设施加验证（灰度按其方向和
///    量级直接对分），否则按不可信处理；
/// 4. 任何来源的位移超过单帧上限（默认 0.9 帧高）都视为不可信——
///    正常小步滚动到不了这个量级，能到的大多是锁错拍或页面跳变。
public enum ScrollDisplacementResolver {

    public struct Options: Sendable, Equatable {
        /// 投票与配准量级一致(±该比例×帧高)时,采用配准值精化
        public var agreementToleranceFraction: Double = 0.06
        /// 投票无重叠时,配准单独成立所需的灰度假设施加分门槛
        public var visionHypothesisMaximumScore: Double = 18
        /// 投票判“未变”时,配准声称移动所需的近乎完美分数
        public var visionHypothesisUnchangedMaximumScore: Double = 10
        /// 单帧最大可信位移(×帧高),超过返回 nil 让调用方按 mismatch 处理
        public var maximumJumpFraction: Double = 0.9

        public init() {}
    }

    /// - visionRows: Vision 配准的全分辨率有符号位移(nil=不可用)
    /// - grayMatch: 灰度五分区投票结果(nil=无重叠;offsetRows==0=未变)
    /// - visionHypothesisScore: 按 vision 方向和量级直接对分的灰度分
    ///   （visionRows 有效时由调用方用 scoreOffset 计算）
    /// - grayHeight / fullHeight: 灰度行 → 全分辨率行的换算
    /// - 返回: 全分辨率有符号位移(正=向下);nil=不可信(按 mismatch 处理)
    public static func resolve(
        visionRows: Int?,
        grayMatch: ScrollMatch?,
        visionHypothesisScore: Double?,
        grayHeight: Int,
        fullHeight: Int,
        options: Options = Options()
    ) -> Int? {
        guard grayHeight > 0, fullHeight > 0 else { return nil }
        let jumpCap = max(8, Int(Double(fullHeight) * options.maximumJumpFraction))
        let agreementTolerance = max(
            6,
            Int(Double(fullHeight) * options.agreementToleranceFraction)
        )

        let grayValue: Int? = grayMatch.flatMap { match -> Int? in
            guard match.offsetRows > 0 else { return 0 }
            let converted = max(1, Int((
                Double(match.offsetRows) / Double(grayHeight) * Double(fullHeight)
            ).rounded()))
            return match.direction == .down ? converted : -converted
        }

        let visionValue: Int? = visionRows
        let visionMoving = visionValue.map { abs($0) > 1 } ?? false

        // ① 投票有结论
        if let gray = grayValue {
            if gray == 0 {
                // 投票说画面未动:配准必须近乎完美才允许推翻
                if visionMoving, let vision = visionValue,
                   let score = visionHypothesisScore,
                   score <= options.visionHypothesisUnchangedMaximumScore,
                   abs(vision) <= jumpCap {
                    return vision
                }
                return 0
            }
            if let vision = visionValue, visionMoving, abs(vision) <= jumpCap,
               (vision > 0) == (gray > 0),
               abs(abs(vision) - abs(gray)) <= agreementTolerance {
                // 两票一致:用配准值精化(亚像素取整更准)
                return vision
            }
            // 不一致(典型:配准锁到周期倍数)→ 信投票
            return abs(gray) <= jumpCap ? gray : nil
        }

        // ② 投票无重叠:配准单独立场需过假设施加验证
        if let vision = visionValue {
            if !visionMoving { return 0 }
            if let score = visionHypothesisScore,
               score <= options.visionHypothesisMaximumScore,
               abs(vision) <= jumpCap {
                return vision
            }
        }
        return nil
    }
}
