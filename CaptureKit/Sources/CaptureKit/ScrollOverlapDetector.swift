/// 滚动截图的纯逻辑重叠检测器。
///
/// 输入是两张同尺寸的 8 位灰度小图。若页面向下滚动了 `d` 行，则新图顶部
/// 应与旧图从第 `d` 行开始的内容相同；检测器返回需要追加到长图底部的行数。
public enum ScrollOverlapDetector {
    public static func appendedRowCount(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        maximumDifference: Double = 18,
        preferredOffset: Int? = nil
    ) -> Int? {
        guard width >= 8, height >= 16,
              previous.count == width * height,
              current.count == previous.count else { return nil }

        let identicalScore = difference(
            previous: previous,
            current: current,
            width: width,
            height: height,
            offset: 0,
            keptFraction: 0.96
        )
        if identicalScore < 2 { return 0 }

        let minOffset = max(2, height / 100)
        // Page Down 和较快的触控板滚动通常只保留约 5%–15% 的可见重叠。
        // 旧上限 82% 会把这类正常操作判成完全不相关；而且 previous 不会
        // 前移，之后即使恢复小步滚动也无法继续拼接。保留至少 5% 画面用于
        // 校验，既覆盖常见大步滚动，也避免在零重叠时猜测内容。
        let maxOffset = max(minOffset, Int(Double(height) * 0.95))
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
        // 大面积纯色、留白或重复卡片会让多个偏移得到几乎相同的分数。自动
        // 滚动知道自己发送的大致步长，近似并列时优先靠近它；只有视觉分数
        // 明显更好时才偏离该提示，避免把 140 px 滚动误判成 2 px。
        if let preferredOffset {
            let nearBestLimit = min(maximumDifference, bestScore + 1.5)
            return candidates
                .filter { $0.score <= nearBestLimit }
                .min {
                    let lhsDistance = abs($0.offset - preferredOffset)
                    let rhsDistance = abs($1.offset - preferredOffset)
                    return lhsDistance == rhsDistance
                        ? $0.score < $1.score
                        : lhsDistance < rhsDistance
                }?
                .offset
        }
        return candidates.min { $0.score < $1.score }?.offset
    }

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
        // 固定导航栏、地址栏和悬浮工具条通常停在画面顶部/底部，不应参与
        // 位移匹配；竞品也建议避开滚动条和浮动工具。这里在算法层再兜底。
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
        // 72% 行做截尾均值，可容忍局部变化，又不会放过整帧无关内容。
        rowScores.sort()
        let keptCount = max(1, Int(Double(rowScores.count) * keptFraction))
        let kept = rowScores.prefix(keptCount)
        return kept.reduce(0, +) / Double(kept.count)
    }
}
