/// 拼接前的最后一道闸门：新条带是否与长图已拼接的边界"逐像素几乎相同"。
///
/// 准周期内容（高度规整的消息卡片流）上，"真实位移 ± 整数个周期"在重叠
/// 检测里得分完全相同，任何匹配算法都可能锁错拍——位移一旦高估，被当作
/// "新内容"追加的条带其实是已拼接内容的原样复现（实测可重复到连计时器
/// 秒数都一致）。这类错误条带与长图尾部/头部几乎逐像素相同，而真正的新
/// 内容（哪怕卡片外观相同，文字/截图必然不同）差异显著，据此拦截。
public enum ScrollDuplicateGuard {

    public enum Insertion: Sendable {
        /// 追加到底部：条带开头（最旧内容）对长图尾部结尾（最近内容）
        case append
        /// 插入到顶部：条带结尾（最新内容）对长图头部开头（最旧内容）
        case prepend
    }

    /// - newRows: 新条带每行的采样亮度向量（自上而下）
    /// - boundaryRows: 拼接边界的最近行缓存（自上而下）
    /// - 返回 true = 判定重复，调用方应放弃本次拼接（不推进锚点）
    public static func isDuplicate(
        newRows: [[UInt8]],
        boundaryRows: [[UInt8]],
        insertion: Insertion,
        maximumMeanDifference: Double = 4,
        minimumComparableRows: Int = 8
    ) -> Bool {
        let comparable = min(newRows.count, boundaryRows.count)
        guard comparable >= minimumComparableRows else { return false }
        let strip: ArraySlice<[UInt8]>
        let boundary: ArraySlice<[UInt8]>
        switch insertion {
        case .append:
            strip = newRows.prefix(comparable)
            boundary = boundaryRows.suffix(comparable)
        case .prepend:
            strip = newRows.suffix(comparable)
            boundary = boundaryRows.prefix(comparable)
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
        guard count > 0 else { return false }
        return Double(total) / Double(count) <= maximumMeanDifference
    }
}
