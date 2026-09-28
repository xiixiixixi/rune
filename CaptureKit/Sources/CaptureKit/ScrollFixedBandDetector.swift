/// 首帧边缘可确认的固定栏高度，单位为输入灰度图的像素行。
public struct ScrollFixedBands: Sendable, Equatable {
    public let topRows: Int
    public let bottomRows: Int

    public init(topRows: Int, bottomRows: Int) {
        self.topRows = topRows
        self.bottomRows = bottomRows
    }
}

/// 比较两张同尺寸灰度帧，保守地寻找固定在视口顶部或底部的横向栏。
///
/// 一对画面无法从像素上区分“真正的固定栏”与“恰好完全相同的重复内容”。
/// 因此只有边缘连续静止、栏内有横向纹理、紧邻正文跨大部分宽度移动时才裁；
/// 证据不足一律返回零，交给后续重叠检测处理。
public enum ScrollFixedBandDetector {
    public static func detect(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int
    ) -> ScrollFixedBands {
        let none = ScrollFixedBands(topRows: 0, bottomRows: 0)
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, width >= 32, height >= 32,
              previous.count == pixelCount, current.count == pixelCount else {
            return none
        }

        let bucketCount = min(8, width / 8)
        let minimumBandRows = max(4, height / 100)
        let maximumBandRows = min(200, height / 5)
        guard maximumBandRows >= minimumBandRows else { return none }

        var topRows = 0
        while topRows < maximumBandRows,
              stationaryRow(topRows, previous: previous, current: current,
                            width: width, bucketCount: bucketCount) {
            topRows += 1
        }
        // 若静止区域超出合理栏高，它更可能是整页没动或大片重复内容。
        if topRows == maximumBandRows,
           stationaryRow(topRows, previous: previous, current: current,
                         width: width, bucketCount: bucketCount) {
            topRows = 0
        } else if topRows < minimumBandRows
                    || !hasHorizontalTexture(previous, width: width, rows: 0..<topRows)
                    || !adjacentContentMoved(
                        previous: previous, current: current, width: width, height: height,
                        boundary: topRows, towardBottom: true, bucketCount: bucketCount
                    ) {
            topRows = 0
        }

        var bottomRows = 0
        while bottomRows < maximumBandRows,
              stationaryRow(height - 1 - bottomRows, previous: previous, current: current,
                            width: width, bucketCount: bucketCount) {
            bottomRows += 1
        }
        if bottomRows == maximumBandRows,
           stationaryRow(height - 1 - bottomRows, previous: previous, current: current,
                         width: width, bucketCount: bucketCount) {
            bottomRows = 0
        } else if bottomRows < minimumBandRows
                    || !hasHorizontalTexture(
                        previous, width: width, rows: (height - bottomRows)..<height
                    )
                    || !adjacentContentMoved(
                        previous: previous, current: current, width: width, height: height,
                        boundary: height - bottomRows, towardBottom: false,
                        bucketCount: bucketCount
                    ) {
            bottomRows = 0
        }

        return ScrollFixedBands(topRows: topRows, bottomRows: bottomRows)
    }

    private static func stationaryRow(
        _ row: Int,
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        bucketCount: Int
    ) -> Bool {
        for bucket in 0..<bucketCount {
            let start = bucket * width / bucketCount
            let end = (bucket + 1) * width / bucketCount
            var difference = 0
            for x in start..<end {
                let index = row * width + x
                difference += abs(Int(previous[index]) - Int(current[index]))
            }
            // 整个横向栏都要近乎不变；一块动态侧栏会否决该行。
            if difference > 4 * (end - start) { return false }
        }
        return true
    }

    private static func hasHorizontalTexture(
        _ pixels: [UInt8],
        width: Int,
        rows: Range<Int>
    ) -> Bool {
        var minimum: UInt8 = 255
        var maximum: UInt8 = 0
        var edgeCount = 0
        var texturedRows = 0
        for row in rows {
            let start = row * width
            var rowEdges = 0
            for x in 0..<width {
                let value = pixels[start + x]
                minimum = min(minimum, value)
                maximum = max(maximum, value)
                if x > 0, abs(Int(value) - Int(pixels[start + x - 1])) >= 12 {
                    rowEdges += 1
                }
            }
            edgeCount += rowEdges
            if rowEdges >= 2 { texturedRows += 1 }
        }
        // 缩到约 192 像素宽后，浅灰底栏上的文字往往只剩 12–20 级亮度差。
        // 横向边缘数量仍必须足够，不能把一整块浅色留白认成工具栏。
        return Int(maximum) - Int(minimum) >= 12
            && texturedRows >= 2
            && edgeCount >= max(4, rows.count * (width - 1) / 200)
    }

    private static func adjacentContentMoved(
        previous: [UInt8],
        current: [UInt8],
        width: Int,
        height: Int,
        boundary: Int,
        towardBottom: Bool,
        bucketCount: Int
    ) -> Bool {
        let window = max(3, min(12, height / 8))
        let rows = towardBottom
            ? boundary..<min(height, boundary + window)
            : max(0, boundary - window)..<boundary
        guard rows.count >= 3 else { return false }

        var movingBuckets = 0
        for bucket in 0..<bucketCount {
            let start = bucket * width / bucketCount
            let end = (bucket + 1) * width / bucketCount
            var difference = 0
            for row in rows {
                for x in start..<end {
                    let index = row * width + x
                    difference += abs(Int(previous[index]) - Int(current[index]))
                }
            }
            if difference > 8 * rows.count * (end - start) {
                movingBuckets += 1
            }
        }
        return movingBuckets * 5 >= bucketCount * 3
    }
}
