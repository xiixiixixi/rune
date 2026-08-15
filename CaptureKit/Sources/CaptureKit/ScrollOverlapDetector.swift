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
        let yStep = max(1, overlapHeight / 96)
        var total = 0
        var count = 0

        var y = 0
        while y < overlapHeight {
            var x = xStart
            while x < xEnd {
                let oldValue = Int(previous[(y + offset) * width + x])
                let newValue = Int(current[y * width + x])
                total += abs(oldValue - newValue)
                count += 1
                x += xStep
            }
            y += yStep
        }
        return count > 0 ? Double(total) / Double(count) : .greatestFiniteMagnitude
    }
}
