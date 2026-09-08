/// 向上/向下滚动共用的长图区间跟踪器（纯逻辑）。
///
/// 内容坐标以首帧顶行为 0。每帧报告相对上一帧的纵向位移（正 = 向下滚动），
/// 跟踪器维护"已捕获内容区间 [capturedMin, capturedMax)"：
/// - 向下滚出新内容 → `appendBottom`：当前帧里区间之下新出现的底行
/// - 向上滚出新内容 → `prependTop`：当前帧顶部区间之上的新行
/// - 滚回已捕获区间（回退）→ `rollback`：不重复拼接，只推进锚点
///
/// 这正是聊天记录的路径：先向下翻几屏，再向上补历史，再向下继续——
/// 区间判断保证任何顺序都不会把同一段内容拼两次。
public struct ScrollRangeTracker: Sendable, Equatable {

    public enum Plan: Sendable, Equatable {
        /// 画面没动。
        case unchanged
        /// 向下滚出新内容：从当前帧 `frameRows` 裁出 `rows` 行接到底部。
        case appendBottom(rows: Int, frameRows: Range<Int>)
        /// 向上滚出新内容：从当前帧顶部 `frameRows` 裁出 `rows` 行插到顶部。
        case prependTop(rows: Int, frameRows: Range<Int>)
        /// 滚回了已捕获区间——回退，不重复拼接。
        case rollback
        /// 位移超出整帧高度，两帧没有重叠。
        case lostOverlap
    }

    /// 已捕获内容区间（首帧顶行为 0，向下为正；min 可为负 = 高于首帧顶部的老内容）。
    public private(set) var capturedMin: Int
    public private(set) var capturedMax: Int
    /// 上一帧在内容坐标里的起始行。
    public private(set) var lastStart: Int
    /// 单帧高度（像素行）。
    public let frameHeight: Int

    public init(frameHeight: Int) {
        precondition(frameHeight > 0, "frameHeight 必须为正")
        self.frameHeight = frameHeight
        capturedMin = 0
        capturedMax = frameHeight
        lastStart = 0
    }

    /// 喂入当前帧相对上一帧的位移（正 = 向下滚动，负 = 向上），返回拼接决策。
    public mutating func advance(byRows displacement: Int) -> Plan {
        guard displacement != 0 else { return .unchanged }
        guard abs(displacement) < frameHeight else { return .lostOverlap }

        let newStart = lastStart + displacement
        let newEnd = newStart + frameHeight
        defer { lastStart = newStart }

        if newEnd > capturedMax {
            let rows = newEnd - capturedMax
            let frameStart = capturedMax - newStart
            capturedMax = newEnd
            return .appendBottom(rows: rows, frameRows: frameStart..<(frameStart + rows))
        }
        if newStart < capturedMin {
            let rows = capturedMin - newStart
            capturedMin = newStart
            return .prependTop(rows: rows, frameRows: 0..<rows)
        }
        return .rollback
    }
}
