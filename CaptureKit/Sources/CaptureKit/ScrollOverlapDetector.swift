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
        maximumDifference: Double = 18
    ) -> Int? {
        guard width >= 8, height >= 16,
              previous.count == width * height,
              current.count == previous.count else { return nil }

        let identicalScore = difference(
            previous: previous,
            current: current,
            width: width,
            height: height,
            offset: 0
        )
        if identicalScore < 2 { return 0 }

        let minOffset = max(2, height / 100)
        let maxOffset = max(minOffset, Int(Double(height) * 0.82))
        var bestOffset: Int?
        var bestScore = Double.greatestFiniteMagnitude

        for offset in minOffset...maxOffset {
            let score = difference(
                previous: previous,
                current: current,
                width: width,
                height: height,
                offset: offset
            )
            if score < bestScore {
                bestScore = score
                bestOffset = offset
            }
        }

        guard bestScore <= maximumDifference else { return nil }
        return bestOffset
    }

    private static func difference(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        offset: Int
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
        let keptCount = max(1, Int(Double(rowScores.count) * 0.72))
        let kept = rowScores.prefix(keptCount)
        return kept.reduce(0, +) / Double(kept.count)
    }
}
