/// 滚动截图的纯逻辑重叠检测器。
///
/// 输入是两张同尺寸的 8 位灰度小图。若页面向下滚动了 `d` 行，则新图顶部
/// 应与旧图从第 `d` 行开始的内容相同；若向上滚动，则新图底部与旧图顶部
/// 内容对齐——把两张图垂直翻转后就归结为同一种"向下"检测。
///
/// 位移判定用 ScrollSnap 式多分区投票：把重叠区横向分成最多 5 条带，
/// 每条带独立找最优位移，至少 4 条带结果接近才接受。滚动条、吸顶栏、
/// 局部动画、聊天头像这些污染源只能带偏少数带，带不走多数票。
public enum ScrollDirection: String, Sendable {
    case down
    case up
}

/// 一次成功的相邻帧匹配结果。
public struct ScrollMatch: Sendable, Equatable {
    /// 滚动方向。`offsetRows == 0`（画面未变）时无意义，约定为 `.down`。
    public let direction: ScrollDirection
    /// 位移行数（灰度行，> 0）。0 = 画面未变。
    public let offsetRows: Int
    /// 共识带的平均匹配分，越小越可信（供调用方比较/诊断）。
    public let score: Double

    public init(direction: ScrollDirection, offsetRows: Int, score: Double) {
        self.direction = direction
        self.offsetRows = offsetRows
        self.score = score
    }
}

/// 一张灰度小图（像素按行主序，行宽 = width）。
public struct ScrollGrayFrame: Sendable, Equatable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

public enum ScrollOverlapDetector {

    // MARK: - 检测入口

    /// 判定相邻两帧之间的滚动位移（方向 + 行数）。
    ///
    /// - 返回 `offsetRows == 0`：画面未变。
    /// - 返回非 0：按 `direction` 滚动了 `offsetRows` 灰度行。
    /// - 返回 nil：两帧找不到可信重叠（失去重叠 / 完全无关）。
    ///
    /// `preferredOffset` / `preferredDirection` 是先验提示（自动滚动知道步长、
    /// 上一帧的方向），只在近似并列时用于打破平局，不会压过明显更好的分数。
    /// `maximumOffset` 是硬上限（灰度行）；自动滚动可用已知滚轮步长排除
    /// 周期卡片或大面积留白产生的远距离假匹配。nil 保持原来的 95% 帧高范围。
    public static func detectScroll(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        maximumDifference: Double = 18,
        preferredOffset: Int? = nil,
        preferredDirection: ScrollDirection? = nil,
        maximumOffset: Int? = nil,
        minimumOffset: Int? = nil,
        fixedDirection: ScrollDirection? = nil
    ) -> ScrollMatch? {
        guard width >= 8, height >= 16,
              previous.count == width * height,
              current.count == previous.count else { return nil }

        if isUnchanged(previous: previous, current: current, width: width, height: height) {
            return ScrollMatch(direction: .down, offsetRows: 0, score: 0)
        }

        let down = fixedDirection == .up ? nil : detectOffset(
            previous: previous,
            current: current,
            width: width,
            height: height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset,
            maximumOffset: maximumOffset,
            minimumOffset: minimumOffset
        )
        let up = fixedDirection == .down ? nil : detectOffset(
            previous: flipped(previous, width: width, height: height),
            current: flipped(current, width: width, height: height),
            width: width,
            height: height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset,
            maximumOffset: maximumOffset,
            minimumOffset: minimumOffset
        )

        switch (down, up) {
        case (nil, nil):
            return nil
        case (let match?, nil):
            return ScrollMatch(direction: .down, offsetRows: match.offset, score: match.score)
        case (nil, let match?):
            return ScrollMatch(direction: .up, offsetRows: match.offset, score: match.score)
        case (let downMatch?, let upMatch?):
            // 双向都能对上：大面积留白、重复卡片、周期性内容的典型症状。
            // 分数明显更好者优先；近似并列时听先验方向。
            let nearTie = abs(downMatch.score - upMatch.score) <= 1.5
            if nearTie, let preferredDirection {
                return preferredDirection == .down
                    ? ScrollMatch(direction: .down, offsetRows: downMatch.offset, score: downMatch.score)
                    : ScrollMatch(direction: .up, offsetRows: upMatch.offset, score: upMatch.score)
            }
            return downMatch.score <= upMatch.score
                ? ScrollMatch(direction: .down, offsetRows: downMatch.offset, score: downMatch.score)
                : ScrollMatch(direction: .up, offsetRows: upMatch.offset, score: upMatch.score)
        }
    }

    /// 画面是否基本没变（用于"滚轮发出后等停稳"的稳定门）。
    public static func isUnchanged(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        threshold: Double = 2
    ) -> Bool {
        guard width >= 8, height >= 16,
              previous.count == width * height,
              current.count == previous.count else { return false }
        let score = difference(
            previous: previous,
            current: current,
            width: width,
            height: height,
            offset: 0,
            keptFraction: 0.96
        )
        return score < threshold
    }

    /// 在指定方向上按指定位移直接打分（供外部验证某假设位移，如校准
    /// Vision 配准给出的方向）。返回 nil 表示该位移不可评估（越界）。
    public static func scoreOffset(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        offsetRows: Int,
        direction: ScrollDirection
    ) -> Double? {
        guard width >= 8, height >= 16, offsetRows > 0 else { return nil }
        if direction == .up {
            return difference(
                previous: flipped(previous, width: width, height: height),
                current: flipped(current, width: width, height: height),
                width: width,
                height: height,
                offset: offsetRows
            )
        }
        return difference(
            previous: previous,
            current: current,
            width: width,
            height: height,
            offset: offsetRows
        )
    }

    // MARK: - 单方向位移检测（五分区投票）

    private struct OffsetMatch: Equatable {
        let offset: Int
        let score: Double
    }

    private static func detectOffset(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        maximumDifference: Double,
        preferredOffset: Int?,
        maximumOffset: Int?,
        minimumOffset: Int? = nil
    ) -> OffsetMatch? {
        let minOffset = max(max(2, height / 100), minimumOffset ?? 0)
        // Page Down 和较快的触控板滚动通常只保留约 5%–15% 的可见重叠。
        // 保留至少 5% 画面用于校验，既覆盖常见大步滚动，也避免零重叠时瞎猜。
        let originalMaxOffset = max(minOffset, Int(Double(height) * 0.95))
        let maxOffset = min(originalMaxOffset, maximumOffset ?? originalMaxOffset)
        guard maxOffset >= minOffset else { return nil }

        let bandCount = height >= 80 ? 5 : (height >= 40 ? 3 : 1)
        let offsets = Array(minOffset...maxOffset)
        var scoresByOffset = [[Double]]()
        scoresByOffset.reserveCapacity(offsets.count)
        for offset in offsets {
            scoresByOffset.append(bandScores(
                previous: previous,
                current: current,
                width: width,
                height: height,
                offset: offset,
                bandCount: bandCount
            ))
        }

        // 每条带的最优位移 + 判别力。大面积纯色带在任何位移下得分都相同，
        // 没有判别力——让它们投票只会用默认值淹没真正携带纹理的带。
        var bestByBand = [Int]()
        var informativeBest = [Int]()
        var informativeIndices = Set<Int>()
        for band in 0..<bandCount {
            var bestOffset = offsets[0]
            var bestScore = Double.greatestFiniteMagnitude
            for (index, offset) in offsets.enumerated() {
                let score = scoresByOffset[index][band]
                if score < bestScore {
                    bestScore = score
                    bestOffset = offset
                }
            }
            bestByBand.append(bestOffset)

            let bandScoresAcrossOffsets = offsets.indices.map { scoresByOffset[$0][band] }
            let sorted = bandScoresAcrossOffsets.sorted()
            let median = sorted[sorted.count / 2]
            if bestScore.isFinite, median - bestScore > 2.0 {
                informativeBest.append(bestOffset)
                informativeIndices.insert(band)
            }
        }

        // 有判别力的带投票：≥4 带时容忍 1 带跑偏（局部动画/污染）；
        // 只有 2–3 带有判别力时要求全体一致。
        let requiredConsensus: Int
        switch informativeBest.count {
        case 4...: requiredConsensus = informativeBest.count - 1
        case 2...3: requiredConsensus = informativeBest.count
        default: requiredConsensus = 0
        }

        if requiredConsensus >= 2 {
            let tolerance = max(1, height / 64)
            let sortedBest = informativeBest.sorted()
            var cluster = [Int]()
            var windowStart = 0
            for windowEnd in sortedBest.indices {
                while sortedBest[windowEnd] - sortedBest[windowStart] > tolerance {
                    windowStart += 1
                }
                if windowEnd - windowStart + 1 > cluster.count {
                    cluster = Array(sortedBest[windowStart...windowEnd])
                }
            }
            if cluster.count >= requiredConsensus {
                // 簇内取中位数；给了步长先验时取离先验最近的簇成员
                // （近似并列时优先靠近已知步长，避免把 140 px 滚动误判成 2 px）。
                let offset: Int
                if let preferredOffset {
                    offset = cluster.min {
                        abs($0 - preferredOffset) == abs($1 - preferredOffset)
                            ? $0 < $1
                            : abs($0 - preferredOffset) < abs($1 - preferredOffset)
                    } ?? cluster[cluster.count / 2]
                } else {
                    offset = cluster[cluster.count / 2]
                }

                // 质量门：共识带在最终位移上的平均分必须足够好
                let offsetIndex = offset - minOffset
                var total = 0.0
                var counted = 0
                for band in informativeIndices {
                    let score = scoresByOffset[offsetIndex][band]
                    if score.isFinite {
                        total += score
                        counted += 1
                    }
                }
                if counted > 0 {
                    let score = total / Double(counted)
                    if score <= maximumDifference {
                        let voted = OffsetMatch(offset: offset, score: score)
                        guard maximumOffset != nil else { return voted }
                        return verifyBoundedOffset(
                            previous: previous, current: current,
                            width: width, height: height,
                            minOffset: minOffset, maxOffset: maxOffset,
                            maximumDifference: maximumDifference,
                            tentative: voted
                        )
                    }
                }
            }
        }

        // 回退：整帧打分。大面积留白页面判别带不足时，纹理稀疏但真实存在，
        // 整帧截尾均值 + 步长先验仍能可靠定位（v0.8.12 的成熟路径）。
        let fallback = wholeFrameBestOffset(
            previous: previous,
            current: current,
            width: width,
            height: height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset,
            maximumOffset: maxOffset
        )
        guard maximumOffset != nil, let fallback else { return fallback }
        return verifyBoundedOffset(
            previous: previous, current: current,
            width: width, height: height,
            minOffset: minOffset, maxOffset: maxOffset,
            maximumDifference: maximumDifference,
            tentative: fallback
        )
    }

    /// 硬上限模式用于自动滚动。五分区和整帧的 72% 截尾分会在大面积留白时
    /// 把少数真正不同的行丢掉，令上限附近的假位移也拿到零分；这里保留 96%
    /// 行重新比较所有已限定的候选。证据仍普遍模糊时放弃本帧，不猜位移。
    private static func verifyBoundedOffset(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        minOffset: Int,
        maxOffset: Int,
        maximumDifference: Double,
        tentative: OffsetMatch
    ) -> OffsetMatch? {
        var candidates: [OffsetMatch] = []
        candidates.reserveCapacity(maxOffset - minOffset + 1)
        for offset in minOffset...maxOffset {
            let score = difference(
                previous: previous, current: current,
                width: width, height: height,
                offset: offset, keptFraction: 0.96
            )
            candidates.append(OffsetMatch(offset: offset, score: score))
        }
        guard let best = candidates.min(by: { $0.score < $1.score }),
              best.score <= maximumDifference else { return nil }

        let nearBest = candidates.filter { $0.score <= best.score + 1.5 }
        guard nearBest.count <= max(3, candidates.count / 3) else { return nil }
        if let agreed = nearBest.first(where: { $0.offset == tentative.offset }) {
            return agreed
        }
        return best
    }

    private static func wholeFrameBestOffset(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        maximumDifference: Double,
        preferredOffset: Int?,
        maximumOffset: Int,
        minimumOffset: Int? = nil
    ) -> OffsetMatch? {
        let minOffset = max(max(2, height / 100), minimumOffset ?? 0)
        let originalMaxOffset = max(minOffset, Int(Double(height) * 0.95))
        let maxOffset = min(originalMaxOffset, maximumOffset)
        guard maxOffset >= minOffset else { return nil }

        var candidates: [(offset: Int, score: Double)] = []
        var bestScore = Double.greatestFiniteMagnitude
        for offset in minOffset...maxOffset {
            let score = difference(
                previous: previous,
                current: current,
                width: width,
                height: height,
                offset: offset
            )
            candidates.append((offset, score))
            if score < bestScore {
                bestScore = score
            }
        }
        guard bestScore <= maximumDifference else { return nil }
        // 大面积纯色、留白或重复卡片会让多个偏移得到相同分数。
        // - 有步长先验（自动模式）：近似并列时优先靠近已知步长；
        // - 无先验（手动模式）：同分取最小位移——准周期内容上
        //   "真实位移 ± 整数个周期"得分完全相同，最小解几乎总是真解
        //   （用户小步滚动），乱取会把已截内容再拼一遍。
        let chosen: (offset: Int, score: Double)
        if let preferredOffset {
            let nearBestLimit = min(maximumDifference, bestScore + 1.5)
            chosen = candidates
                .filter { $0.score <= nearBestLimit }
                .min {
                    let lhsDistance = abs($0.offset - preferredOffset)
                    let rhsDistance = abs($1.offset - preferredOffset)
                    return lhsDistance == rhsDistance
                        ? $0.score < $1.score
                        : lhsDistance < rhsDistance
                } ?? (candidates.min { $0.score < $1.score } ?? (minOffset, bestScore))
        } else {
            chosen = candidates.min {
                $0.score == $1.score ? $0.offset < $1.offset : $0.score < $1.score
            } ?? (minOffset, bestScore)
        }
        return OffsetMatch(offset: chosen.offset, score: chosen.score)
    }

    // MARK: - 长图尾部锚定（失配自愈）

    /// 把一帧对齐到「已拼接长图的尾部」（ShareX 与成品比对思想的原创实现）。
    ///
    /// 常规检测只比较相邻两帧；惯性滚动、局部动画或懒加载把某一帧弄脏后，
    /// 相邻配准失败，会话就会卡在失配。但已拼接的长图尾部是干净、稳定的
    /// 像素——若当前帧顶部仍与尾部强重叠，说明中间并没有漏内容，只是上一
    /// 帧瞬间不可用，可以无损续接。
    ///
    /// - Parameters:
    ///   - tail: 长图末尾的灰度行（行宽与帧一致，行数 = `tailHeight`）。
    ///   - minimumOverlap: 接受锚定所需的最少重叠灰度行。
    /// - Returns: `anchorRow` = 当前帧顶行在尾部坐标系中的行号；
    ///   `overlapRows` = 实际可比对的行数；`score` = 截尾均分（同常规门槛）。
    ///   找不到强且无歧义的锚定时返回 nil（宁可不救，不错接）。
    /// 行向量版尾部锚定：尾部缓存与当前帧都用同一套行采样口径，
    /// 才能直接比对。像素版（`detectTailAnchor(tail:tailHeight:current:width:height:)`）
    /// 要求尾部是**原始像素行**，而生产链路里的尾部缓存是 24 采样的行向量——
    /// 两者混用会让长度校验直接失败，整条自愈路径静默失效。
    public static func detectTailAnchor(
        tailRows: [[UInt8]],
        currentRows: [[UInt8]],
        minimumOverlap: Int,
        maximumDifference: Double = 18
    ) -> (anchorRow: Int, overlapRows: Int, score: Double)? {
        let tailHeight = tailRows.count
        let currentHeight = currentRows.count
        guard tailHeight >= minimumOverlap, currentHeight >= minimumOverlap,
              !tailRows.isEmpty, !currentRows.isEmpty,
              let sampleCount = tailRows.first?.count,
              sampleCount > 0,
              currentRows.allSatisfy({ $0.count == sampleCount }),
              tailRows.allSatisfy({ $0.count == sampleCount }) else { return nil }

        let firstAnchor = max(0, tailHeight - currentHeight)
        let lastAnchor = tailHeight - minimumOverlap
        guard lastAnchor >= firstAnchor else { return nil }

        var candidates: [(anchor: Int, score: Double)] = []
        candidates.reserveCapacity(lastAnchor - firstAnchor + 1)
        for anchor in firstAnchor...lastAnchor {
            candidates.append((anchor, tailDifference(
                tailRows: tailRows,
                currentRows: currentRows,
                anchorRow: anchor
            )))
        }

        guard let best = candidates.min(by: { $0.score < $1.score }),
              best.score <= maximumDifference else { return nil }

        let nearBest = candidates.filter { $0.score <= best.score + 1.5 }
        let chosen = nearBest.min { $0.anchor < $1.anchor } ?? best
        let spread = max(4, currentHeight / 16)
        guard nearBest.allSatisfy({ abs($0.anchor - chosen.anchor) <= spread }) else {
            return nil
        }
        let overlap = min(currentHeight, tailHeight - chosen.anchor)
        return (anchorRow: chosen.anchor, overlapRows: overlap, score: chosen.score)
    }

    /// 行向量版尾部打分：当前帧第 y 行 ↔ 尾部第 anchor+y 行。
    private static func tailDifference(
        tailRows: [[UInt8]],
        currentRows: [[UInt8]],
        anchorRow: Int
    ) -> Double {
        let overlapHeight = min(currentRows.count, tailRows.count - anchorRow)
        guard overlapHeight > 0 else { return .greatestFiniteMagnitude }
        let edge = max(2, overlapHeight / 8)
        let yStart = edge
        let yEnd = overlapHeight - edge
        guard yEnd - yStart >= 4 else { return .greatestFiniteMagnitude }
        let yStep = max(1, (yEnd - yStart) / 96)
        var rowScores: [Double] = []

        var y = yStart
        while y < yEnd {
            let tailRow = tailRows[anchorRow + y]
            let currentRow = currentRows[y]
            var total = 0
            for index in 0..<min(tailRow.count, currentRow.count) {
                total += abs(Int(tailRow[index]) - Int(currentRow[index]))
            }
            rowScores.append(Double(total) / Double(max(1, min(tailRow.count, currentRow.count))))
            y += yStep
        }

        guard !rowScores.isEmpty else { return .greatestFiniteMagnitude }
        rowScores.sort()
        let keptCount = max(1, Int(Double(rowScores.count) * 0.72))
        let kept = rowScores.prefix(keptCount)
        return kept.reduce(0, +) / Double(kept.count)
    }

    public static func detectTailAnchor(
        tail: [UInt8],
        tailHeight: Int,
        current: [UInt8],
        width: Int,
        height: Int,
        minimumOverlap: Int,
        maximumDifference: Double = 18
    ) -> (anchorRow: Int, overlapRows: Int, score: Double)? {
        guard width >= 8, height >= 16,
              tail.count == width * tailHeight,
              current.count == width * height,
              minimumOverlap >= 8,
              tailHeight >= minimumOverlap else { return nil }

        // anchorRow 从「整帧都在尾部内」扫到「只剩最低重叠」：
        // 越靠后重叠越少，但覆盖了新内容在尾部之下生长的常见情形。
        let firstAnchor = max(0, tailHeight - height)
        let lastAnchor = tailHeight - minimumOverlap
        guard lastAnchor >= firstAnchor else { return nil }

        var candidates: [(anchor: Int, score: Double)] = []
        candidates.reserveCapacity(lastAnchor - firstAnchor + 1)
        for anchor in firstAnchor...lastAnchor {
            let score = tailDifference(
                tail: tail, tailHeight: tailHeight,
                current: current, width: width,
                anchorRow: anchor, frameHeight: height
            )
            candidates.append((anchor, score))
        }

        guard let best = candidates.min(by: { $0.score < $1.score }),
              best.score <= maximumDifference else { return nil }

        // 歧义检查：渐变背景、周期卡片会让"远处"也拿到相近的低分。
        // 真锚点周围因亚像素过渡只有少数相邻行近分；若近分锚点散开
        // （不在一个窄窗口内），说明位移本身不确定，宁可不救不错接。
        let nearBest = candidates.filter { $0.score <= best.score + 1.5 }
        let chosen = nearBest.min { $0.anchor < $1.anchor } ?? best
        let spread = max(4, height / 16)
        guard nearBest.allSatisfy({ abs($0.anchor - chosen.anchor) <= spread }) else {
            return nil
        }

        let overlap = min(height, tailHeight - chosen.anchor)
        return (anchorRow: chosen.anchor, overlapRows: overlap, score: chosen.score)
    }

    /// 尾部锚定专用打分：当前帧第 y 行 ↔ 尾部第 anchor+y 行。
    /// 列采样与 difference() 一致（中段 80% 列、行分 72% 截尾均值），
    /// 保证分数门槛语义相同；行采样保留重叠的主体（上下各裁 1/8），
    /// 可采样行不足 4 行时直接判无证据——短重叠的"单行巧合"不可信。
    private static func tailDifference(
        tail: [UInt8],
        tailHeight: Int,
        current: [UInt8],
        width: Int,
        anchorRow: Int,
        frameHeight: Int
    ) -> Double {
        let overlapHeight = min(frameHeight, tailHeight - anchorRow)
        guard overlapHeight > 0 else { return .greatestFiniteMagnitude }
        let xStart = width / 10
        let xEnd = width - xStart
        let xStep = max(1, width / 64)
        let edge = max(2, overlapHeight / 8)
        let yStart = edge
        let yEnd = overlapHeight - edge
        guard yEnd - yStart >= 4 else { return .greatestFiniteMagnitude }
        let yStep = max(1, (yEnd - yStart) / 96)
        var rowScores: [Double] = []

        var y = yStart
        while y < yEnd {
            var rowTotal = 0
            var rowCount = 0
            var x = xStart
            while x < xEnd {
                let tailValue = Int(tail[(anchorRow + y) * width + x])
                let currentValue = Int(current[y * width + x])
                rowTotal += abs(tailValue - currentValue)
                rowCount += 1
                x += xStep
            }
            if rowCount > 0 {
                rowScores.append(Double(rowTotal) / Double(rowCount))
            }
            y += yStep
        }

        guard !rowScores.isEmpty else { return .greatestFiniteMagnitude }
        rowScores.sort()
        let keptCount = max(1, Int(Double(rowScores.count) * 0.72))
        let kept = rowScores.prefix(keptCount)
        return kept.reduce(0, +) / Double(kept.count)
    }

    // MARK: - 底层打分

    /// 重叠区按横带切分逐带打分。每带内逐行采样（左右避开滚动条、
    /// 上下避开吸顶/悬浮层），行分做 72% 截尾均值以容忍局部动画。
    private static func bandScores(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        offset: Int,
        bandCount: Int
    ) -> [Double] {
        let overlapHeight = height - offset
        guard overlapHeight > 0 else {
            return Array(repeating: .greatestFiniteMagnitude, count: bandCount)
        }
        let xStart = width / 10
        let xEnd = width - xStart
        let xStep = max(1, width / 64)
        // 固定导航栏、地址栏和悬浮工具条通常停在画面顶部/底部，不应参与
        // 位移匹配；竞品实践同样建议避开滚动条和浮动工具。
        let edgeBand = max(1, height / 10)
        let yStart = min(edgeBand, max(0, overlapHeight / 4))
        let yEnd = max(yStart + 1, overlapHeight - min(edgeBand, overlapHeight / 4))
        let bandHeight = max(1, (yEnd - yStart) / bandCount)

        var results: [Double] = []
        results.reserveCapacity(bandCount)
        for band in 0..<bandCount {
            let bandStart = yStart + band * bandHeight
            let bandEnd = band == bandCount - 1 ? yEnd : min(yEnd, bandStart + bandHeight)
            guard bandEnd > bandStart else {
                results.append(.greatestFiniteMagnitude)
                continue
            }
            let yStep = max(1, (bandEnd - bandStart) / 24)
            var rowScores: [Double] = []
            var y = bandStart
            while y < bandEnd {
                var rowTotal = 0
                var rowCount = 0
                var x = xStart
                while x < xEnd {
                    let oldValue = Int(previous[(y + offset) * width + x])
                    let newValue = Int(current[y * width + x])
                    rowTotal += abs(oldValue - newValue)
                    rowCount += 1
                    x += xStep
                }
                if rowCount > 0 {
                    rowScores.append(Double(rowTotal) / Double(rowCount))
                }
                y += yStep
            }
            guard !rowScores.isEmpty else {
                results.append(.greatestFiniteMagnitude)
                continue
            }
            rowScores.sort()
            let keptCount = max(1, Int(Double(rowScores.count) * 0.72))
            let kept = rowScores.prefix(keptCount)
            results.append(kept.reduce(0, +) / Double(kept.count))
        }
        return results
    }

    /// 整帧位移分数（offset 0 用于"画面未变"判定）。
    private static func difference(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        offset: Int,
        keptFraction: Double = 0.72
    ) -> Double {
        let overlapHeight = height - offset
        guard overlapHeight > 0 else { return .greatestFiniteMagnitude }
        let xStart = width / 10
        let xEnd = width - xStart
        let xStep = max(1, width / 64)
        let edgeBand = max(1, height / 10)
        let yStart = min(edgeBand, max(0, overlapHeight / 4))
        let yEnd = max(yStart + 1, overlapHeight - min(edgeBand, overlapHeight / 4))
        let yStep = max(1, (yEnd - yStart) / 96)
        var rowScores: [Double] = []

        var y = yStart
        while y < yEnd {
            var rowTotal = 0
            var rowCount = 0
            var x = xStart
            while x < xEnd {
                let oldValue = Int(previous[(y + offset) * width + x])
                let newValue = Int(current[y * width + x])
                rowTotal += abs(oldValue - newValue)
                rowCount += 1
                x += xStep
            }
            if rowCount > 0 {
                rowScores.append(Double(rowTotal) / Double(rowCount))
            }
            y += yStep
        }

        guard !rowScores.isEmpty else { return .greatestFiniteMagnitude }
        // 动态广告、视频、光标和吸顶条会污染少量采样行。取误差最低的
        // keptFraction 行做截尾均值，可容忍局部变化，又不会放过整帧无关内容。
        rowScores.sort()
        let keptCount = max(1, Int(Double(rowScores.count) * keptFraction))
        let kept = rowScores.prefix(keptCount)
        return kept.reduce(0, +) / Double(kept.count)
    }


    // MARK: - 行向量采样

    /// 把一张灰度图按行采样成"每行若干个采样点"的行向量。
    /// 长图尾部缓存、重复闸门、尾部重锚三处必须用同一套采样口径，
    /// 否则行数对得上、采样点对不上，校验会在中途悄悄失败。
    public static func rowVectors(
        pixels: [UInt8],
        width: Int,
        height: Int,
        samples: Int = 24
    ) -> [[UInt8]] {
        guard width > 0, height > 0, samples > 0,
              pixels.count >= width * height else { return [] }
        var vectors: [[UInt8]] = []
        vectors.reserveCapacity(height)
        for y in 0..<height {
            var row: [UInt8] = []
            row.reserveCapacity(samples)
            for sample in 0..<samples {
                let x = min(width - 1, sample * width / samples)
                row.append(pixels[y * width + x])
            }
            vectors.append(row)
        }
        return vectors
    }

    // MARK: - 粗→细两级重叠检测（借鉴 VESDK 的多尺度金字塔搜索）

    /// 粗→细两级重叠检测：先粗测，再在细尺度上窄窗精修。
    ///
    /// 飞书 VESDK 的长图拼接在"重叠区太小"时会换一个更细的尺度重找
    /// （二进制里的原话：`the area is too small current level=%d, scale=%f,
    /// width=%d, height=%d`）。这里做的是同一件事的另一种落地：
    ///
    /// 1. 粗尺度（固定缩到约 192px 宽）先测出位移——快、覆盖范围大；
    /// 2. 细尺度（更宽的缩略图）在粗解**附近开一个窄窗**重测：窄窗保证
    ///    不会跳到周期假匹配，只做精度修正；细尺度里同样的重叠像素能采到
    ///    更多行，位移量化误差从"捕获宽 ÷ 192"降到"捕获宽 ÷ 细尺度宽"；
    /// 3. 细尺度分数达标就采用细解（它的几何更准），否则保留粗解。
    ///
    /// 为什么不能直接"两尺度都搜一遍、分数小的赢"：粗尺度是降采样的，
    /// 失配时的均差天然被模糊压低，粗解的分数会**系统性地**偏乐观。
    /// 窄窗精修没有这个偏差——它只在粗解附近找，不可能换到别的周期。
    ///
    /// - Returns: 位移以**细尺度行数**表达（粗解也会换算到细尺度），
    ///   调用方要用细尺度的行高换算成全分辨率行。
    public static func detectScrollTwoScale(
        coarsePrevious: ScrollGrayFrame,
        coarseCurrent: ScrollGrayFrame,
        finePrevious: ScrollGrayFrame,
        fineCurrent: ScrollGrayFrame,
        maximumDifference: Double = 18,
        preferredOffset: Int? = nil,
        preferredDirection: ScrollDirection? = nil,
        maximumOffset: Int? = nil,
        refinementMarginRows: Int = 3,
        refinementAcceptanceScore: Double = 8
    ) -> ScrollMatch? {
        guard coarsePrevious.pixels.count == coarsePrevious.width * coarsePrevious.height,
              coarseCurrent.pixels.count == coarsePrevious.pixels.count,
              finePrevious.pixels.count == finePrevious.width * finePrevious.height,
              fineCurrent.pixels.count == finePrevious.pixels.count else { return nil }

        let coarse = detectScroll(
            previous: coarsePrevious.pixels,
            current: coarseCurrent.pixels,
            width: coarsePrevious.width,
            height: coarsePrevious.height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset,
            preferredDirection: preferredDirection,
            maximumOffset: maximumOffset
        )
        let scale = Double(finePrevious.height) / Double(max(coarsePrevious.height, 1))
        guard scale > 1.05 else {
            return coarse
        }
        let fineMaximum = maximumOffset.map { Int((Double($0) * scale).rounded()) }
        let finePreferred = preferredOffset.map { Int((Double($0) * scale).rounded()) }

        guard let coarse else {
            // 粗尺度没找到重叠——这正是"滚动距离大、量化误差把重叠抹平"的典型症状。
            // 细尺度的量化更细、重叠采样行更多，是这种"差一点点"的解药：
            // 让它在同样的允许范围内整体重找一次。
            guard let fine = detectScroll(
                previous: finePrevious.pixels,
                current: fineCurrent.pixels,
                width: finePrevious.width,
                height: finePrevious.height,
                maximumDifference: maximumDifference,
                preferredOffset: finePreferred,
                preferredDirection: preferredDirection,
                maximumOffset: fineMaximum
            ) else { return nil }
            return ScrollMatch(
                direction: fine.direction,
                offsetRows: fine.offsetRows,
                score: fine.score
            )
        }
        guard coarse.offsetRows > 0 else { return coarse }

        let center = Int((Double(coarse.offsetRows) * scale).rounded())
        let margin = max(refinementMarginRows, Int((Double(coarsePrevious.height) / 12 * scale).rounded()))

        // 方向跟随粗解；向上滚动先翻转，统一按"向下"搜索
        let workingPrevious = coarse.direction == .up
            ? flipped(finePrevious.pixels, width: finePrevious.width, height: finePrevious.height)
            : finePrevious.pixels
        let workingCurrent = coarse.direction == .up
            ? flipped(fineCurrent.pixels, width: finePrevious.width, height: finePrevious.height)
            : fineCurrent.pixels

        let refined = detectOffset(
            previous: workingPrevious,
            current: workingCurrent,
            width: finePrevious.width,
            height: finePrevious.height,
            maximumDifference: maximumDifference,
            preferredOffset: center,
            maximumOffset: fineMaximum,
            minimumOffset: max(2, center - margin)
        )
        guard let refined, refined.score <= refinementAcceptanceScore else {
            // 细尺度没给出更好的答案：把粗解放大回细尺度行，语义保持统一
            let coarseInFine = Int((Double(coarse.offsetRows) * scale).rounded())
            guard coarseInFine > 0 else { return coarse }
            return ScrollMatch(
                direction: coarse.direction,
                offsetRows: coarseInFine,
                score: coarse.score
            )
        }
        guard refined.offset > 0 else { return coarse }
        return ScrollMatch(
            direction: coarse.direction,
            offsetRows: refined.offset,
            score: refined.score
        )
    }

    private static func flipped(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<height {
            let source = (height - 1 - y) * width
            let destination = y * width
            for x in 0..<width {
                output[destination + x] = pixels[source + x]
            }
        }
        return output
    }
}
