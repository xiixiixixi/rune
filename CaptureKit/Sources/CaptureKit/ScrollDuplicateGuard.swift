/// 拼接前的最后一道闸门：新条带是否与长图已拼接的边界有可信的重复。
///
/// 准周期内容（高度规整的消息卡片流）上，"真实位移 ± 整数个周期"在重叠
/// 检测里得分完全相同，任何匹配算法都可能锁错拍——位移一旦高估，被当作
/// "新内容"追加的条带其实是已拼接内容的原样复现（实测可重复到连计时器
/// 秒数都一致）。这类错误条带与长图尾部/头部几乎逐像素相同，而真正的新
/// 内容（哪怕卡片外观相同，文字/截图必然不同）差异显著，据此拦截。
/// 位移高估时也可能只有新条带的开头/结尾重复；这时要求重复部分至少占
/// 半条且有足够纹理，避免纯色背景被误判为重复内容。
public enum ScrollDuplicateGuard {

    public enum Insertion: Sendable {
        /// 追加到底部：条带开头（最旧内容）对长图尾部结尾（最近内容）
        case append
        /// 插入到顶部：条带结尾（最新内容）对长图头部开头（最旧内容）
        case prepend
    }

    /// 重复程度的测量结果。判定"真重复"还是"仅仅是周期性内容长得像"要靠它：
    /// 真重复是**逐行几乎完全一致**（同一张卡片原样再现），而周期性内容
    /// 前进时只是**整体相似**（同一套版式，宽度/序号不同）。
    public struct RepetitionEvidence: Sendable {
        /// 整体（可比较长度）上的平均绝对差（0–255 灰度）。
        public let meanDifference: Double
        /// 可比较的行数。
        public let comparableRows: Int
        /// 逐行完全一致（差值 ≤ 1）的行占可比较行数的比例。
        /// 真重复接近 1；只是版式相同则明显更低。
        public let verbatimRowRatio: Double
        /// 是否存在"更短的匹配长度"（周期性内容的典型特征）。
        public let hasShorterMatch: Bool
        /// 更短匹配长度上的逐行一致率（最接近 1 的那个）。
        public let shorterMatchVerbatimRowRatio: Double
    }

    /// 测量新条带与拼接边界的重复程度（不判定，仅取证）。
    /// 供调用方在拦截时记录证据并区分真重复与准周期内容。
    public static func measureRepetition(
        newRows: [[UInt8]],
        boundaryRows: [[UInt8]],
        insertion: Insertion,
        minimumComparableRows: Int = 8
    ) -> RepetitionEvidence? {
        let comparable = min(newRows.count, boundaryRows.count)
        guard comparable >= minimumComparableRows else { return nil }
        guard !isUniform(newRows), !isUniform(boundaryRows) else { return nil }
        let mean = meanDifference(
            newRows: newRows,
            boundaryRows: boundaryRows,
            length: comparable,
            insertion: insertion
        )
        let verbatim = verbatimRowRatio(
            newRows: newRows,
            boundaryRows: boundaryRows,
            length: comparable,
            insertion: insertion
        )
        let tolerance = max(8, newRows.count / 20)
        var hasShorterMatch = false
        var shorterVerbatim = 0.0
        if comparable > minimumComparableRows {
            for length in stride(from: comparable - 1,
                                 through: minimumComparableRows, by: -1)
            where comparable - length > tolerance {
                let shorterMean = meanDifference(
                    newRows: newRows,
                    boundaryRows: boundaryRows,
                    length: length,
                    insertion: insertion
                )
                let ratio = verbatimRowRatio(
                    newRows: newRows,
                    boundaryRows: boundaryRows,
                    length: length,
                    insertion: insertion
                )
                if shorterMean <= 4 {
                    hasShorterMatch = true
                    shorterVerbatim = max(shorterVerbatim, ratio)
                }
            }
        }
        return RepetitionEvidence(
            meanDifference: mean,
            comparableRows: comparable,
            verbatimRowRatio: verbatim,
            hasShorterMatch: hasShorterMatch,
            shorterMatchVerbatimRowRatio: shorterVerbatim
        )
    }

    /// - newRows: 新条带每行的采样亮度向量（自上而下）
    /// - boundaryRows: 拼接边界的最近行缓存（自上而下）
    /// - 返回 true = 判定重复，调用方应放弃本次拼接（不推进锚点）
    public static func isDuplicate(
        newRows: [[UInt8]],
        boundaryRows: [[UInt8]],
        insertion: Insertion,
        maximumMeanDifference: Double = 4,
        minimumComparableRows: Int = 8,
        minimumVerbatimRowRatio: Double = 0.8
    ) -> Bool {
        let comparable = min(newRows.count, boundaryRows.count)
        guard comparable >= minimumComparableRows else { return false }
        // 完全均匀的画面没有可用的视觉锚点，后续所有长度都会同分。
        guard !isUniform(newRows), !isUniform(boundaryRows) else { return false }
        let wholeStripMatches = matches(
            newRows: newRows,
            boundaryRows: boundaryRows,
            length: comparable,
            insertion: insertion,
            maximumMeanDifference: maximumMeanDifference,
            minimumVerbatimRowRatio: minimumVerbatimRowRatio
        )
        if wholeStripMatches {
            // 完整相同也可能只是多张外观完全一致的正常卡片。
            // 若相隔一个周期还有另一种同样成立的匹配长度，无法证明是
            // 已截内容，不应把真实的新卡片永久卡在当前位置。
            let tolerance = max(8, newRows.count / 20)
            if comparable > minimumComparableRows {
                for length in stride(from: comparable - 1,
                                     through: minimumComparableRows, by: -1)
                where comparable - length > tolerance {
                    if matches(
                        newRows: newRows,
                        boundaryRows: boundaryRows,
                        length: length,
                        insertion: insertion,
                        maximumMeanDifference: maximumMeanDifference,
                        minimumVerbatimRowRatio: minimumVerbatimRowRatio
                    ) {
                        return false
                    }
                }
            }
            return true
        }

        // 只拦截较长的部分重复：较短的相同背景/卡片不足以证明锚点错位。
        // 调用方把约 1000px 宽的画面缩到 192px；280 个原图重复行可能只剩
        // 约 54 个采样行。24 行是缩略图尺度上的保守下限。
        let minimumPartialRows = max(24, (newRows.count + 1) / 2)
        guard comparable > minimumPartialRows else { return false }
        var matchedLength: Int?
        let sameMatchTolerance = max(8, newRows.count / 20)
        for length in stride(from: comparable - 1, through: minimumPartialRows, by: -1) {
            if matches(
                newRows: newRows,
                boundaryRows: boundaryRows,
                length: length,
                insertion: insertion,
                maximumMeanDifference: maximumMeanDifference,
                minimumVerbatimRowRatio: minimumVerbatimRowRatio
            ) {
                // 周期性卡片可在相隔一个周期的多个长度上同时匹配；无法证明
                // 哪个位置是真正的接缝时保留内容，避免误拦正常的新卡片。
                if let matchedLength, matchedLength - length > sameMatchTolerance {
                    return false
                }
                matchedLength = matchedLength ?? length
            }
        }
        return matchedLength != nil
    }

    private static func matches(
        newRows: [[UInt8]],
        boundaryRows: [[UInt8]],
        length: Int,
        insertion: Insertion,
        maximumMeanDifference: Double,
        minimumVerbatimRowRatio: Double
    ) -> Bool {
        let strip: ArraySlice<[UInt8]>
        let boundary: ArraySlice<[UInt8]>
        switch insertion {
        case .append:
            strip = newRows.prefix(length)
            boundary = boundaryRows.suffix(length)
        case .prepend:
            strip = newRows.suffix(length)
            boundary = boundaryRows.prefix(length)
        }
        // 先抽样排除明显错位，再对候选长度逐像素计算均差。这里使用宽松
        // 门槛；有动画的少数行可能变动，宁可漏拦也不误删正常内容。
        var probeTotal = 0
        var probeCount = 0
        for sample in 0..<min(8, length) {
            let rowIndex = sample * (length - 1) / max(1, min(8, length) - 1)
            let newRow = strip[strip.startIndex + rowIndex]
            let oldRow = boundary[boundary.startIndex + rowIndex]
            for (newValue, oldValue) in zip(newRow, oldRow) {
                probeTotal += abs(Int(newValue) - Int(oldValue))
                probeCount += 1
            }
        }
        guard probeCount > 0,
              Double(probeTotal) / Double(probeCount) <= max(12, maximumMeanDifference * 3)
        else { return false }

        let mean = meanDifference(
            newRows: newRows,
            boundaryRows: boundaryRows,
            length: length,
            insertion: insertion
        )
        guard mean <= maximumMeanDifference else { return false }
        // 均差小还不够：准周期内容（同一套版式、宽度/序号不同）整体均差
        // 也很小，但它是**新内容**。真正的重复是同一批像素原样再现——必须
        // 逐行几乎完全一致。只看均差会把"长得像"误判成"重复"，导致正常
        // 的新卡片被永久卡住、长图停在半路。
        let verbatim = verbatimRowRatio(
            newRows: newRows,
            boundaryRows: boundaryRows,
            length: length,
            insertion: insertion
        )
        guard verbatim >= minimumVerbatimRowRatio else { return false }
        return hasTexture(strip) && hasTexture(boundary)
    }

    /// 指定长度上的平均绝对差（0–255 灰度）。
    private static func meanDifference(
        newRows: [[UInt8]],
        boundaryRows: [[UInt8]],
        length: Int,
        insertion: Insertion
    ) -> Double {
        let strip: ArraySlice<[UInt8]>
        let boundary: ArraySlice<[UInt8]>
        switch insertion {
        case .append:
            strip = newRows.prefix(length)
            boundary = boundaryRows.suffix(length)
        case .prepend:
            strip = newRows.suffix(length)
            boundary = boundaryRows.prefix(length)
        }
        var total = 0
        var count = 0
        for (newRow, oldRow) in zip(strip, boundary) {
            let width = min(newRow.count, oldRow.count)
            guard width > 0 else { continue }
            for x in 0..<width {
                total += abs(Int(newRow[x]) - Int(oldRow[x]))
                count += 1
            }
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        return Double(total) / Double(count)
    }

    /// 逐行完全一致（所有采样列差值 ≤ 1）的行占比。
    /// 真正的"原样重复"接近 1；仅仅是同一套版式的不同卡片明显更低。
    private static func verbatimRowRatio(
        newRows: [[UInt8]],
        boundaryRows: [[UInt8]],
        length: Int,
        insertion: Insertion
    ) -> Double {
        let strip: ArraySlice<[UInt8]>
        let boundary: ArraySlice<[UInt8]>
        switch insertion {
        case .append:
            strip = newRows.prefix(length)
            boundary = boundaryRows.suffix(length)
        case .prepend:
            strip = newRows.suffix(length)
            boundary = boundaryRows.prefix(length)
        }
        var identicalRows = 0
        var totalRows = 0
        for (newRow, oldRow) in zip(strip, boundary) {
            let width = min(newRow.count, oldRow.count)
            guard width > 0 else { continue }
            totalRows += 1
            var identical = true
            for x in 0..<width where abs(Int(newRow[x]) - Int(oldRow[x])) > 1 {
                identical = false
                break
            }
            if identical { identicalRows += 1 }
        }
        guard totalRows > 0 else { return 0 }
        return Double(identicalRows) / Double(totalRows)
    }

    private static func isUniform(_ rows: [[UInt8]]) -> Bool {
        guard let value = rows.first?.first else { return true }
        return rows.allSatisfy { row in row.allSatisfy { $0 == value } }
    }

    /// 至少多行出现横向对比或逐行变化。纯白、纯色和微弱噪声不算锚点。
    private static func hasTexture(_ rows: ArraySlice<[UInt8]>) -> Bool {
        let requiredRows = max(8, rows.count / 10)
        var informativeRows = 0
        var previous: [UInt8]?
        for row in rows {
            guard let lowest = row.min(), let highest = row.max() else { continue }
            var verticalDifference = 0
            if let previous {
                for (value, oldValue) in zip(row, previous) {
                    verticalDifference += abs(Int(value) - Int(oldValue))
                }
            }
            let verticalWidth = previous.map { min(row.count, $0.count) } ?? 0
            if Int(highest) - Int(lowest) >= 24
                || (verticalWidth > 0 && verticalDifference >= 4 * verticalWidth) {
                informativeRows += 1
                if informativeRows >= requiredRows { return true }
            }
            previous = row
        }
        return false
    }
}
