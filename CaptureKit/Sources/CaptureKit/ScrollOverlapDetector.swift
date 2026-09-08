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
    public static func detectScroll(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        maximumDifference: Double = 18,
        preferredOffset: Int? = nil,
        preferredDirection: ScrollDirection? = nil
    ) -> ScrollMatch? {
        guard width >= 8, height >= 16,
              previous.count == width * height,
              current.count == previous.count else { return nil }

        if isUnchanged(previous: previous, current: current, width: width, height: height) {
            return ScrollMatch(direction: .down, offsetRows: 0, score: 0)
        }

        let down = detectOffset(
            previous: previous,
            current: current,
            width: width,
            height: height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset
        )
        let up = detectOffset(
            previous: flipped(previous, width: width, height: height),
            current: flipped(current, width: width, height: height),
            width: width,
            height: height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset
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
        preferredOffset: Int?
    ) -> OffsetMatch? {
        let minOffset = max(2, height / 100)
        // Page Down 和较快的触控板滚动通常只保留约 5%–15% 的可见重叠。
        // 保留至少 5% 画面用于校验，既覆盖常见大步滚动，也避免零重叠时瞎猜。
        let maxOffset = max(minOffset, Int(Double(height) * 0.95))
        guard maxOffset > minOffset else { return nil }

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
                        return OffsetMatch(offset: offset, score: score)
                    }
                }
            }
        }

        // 回退：整帧打分。大面积留白页面判别带不足时，纹理稀疏但真实存在，
        // 整帧截尾均值 + 步长先验仍能可靠定位（v0.8.12 的成熟路径）。
        return wholeFrameBestOffset(
            previous: previous,
            current: current,
            width: width,
            height: height,
            maximumDifference: maximumDifference,
            preferredOffset: preferredOffset
        )
    }

    private static func wholeFrameBestOffset(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        maximumDifference: Double,
        preferredOffset: Int?
    ) -> OffsetMatch? {
        let minOffset = max(2, height / 100)
        let maxOffset = max(minOffset, Int(Double(height) * 0.95))
        guard maxOffset > minOffset else { return nil }

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
