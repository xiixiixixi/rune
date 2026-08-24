import SwiftUI

/// Rune 设计系统——「校样台 Proof Desk」。
///
/// 概念：Rune 是一间数字校样台，截图即校样。界面是车间的纸、墨与工具：
/// - **纸** 冷瓷白（刻意避开暖奶油色），让截图内容成为主角；
/// - **墨** 蓝黑墨线承载文字与描边；
/// - **制图蓝** 唯一主色——校对笔的蓝，只给主按钮、选中态、激活态；
/// - **信号橘** 只出现在录制与危险操作上，像车间的警示灯；
/// - **石墨** 暗色家族给悬浮在画面上的深色表面（确认条、Toast、状态条）；
/// - **裁切角线**（CropMarks）是签名记号：一个裁图工具，身上带着裁切标记。
///
/// 字体见 RuneFont：界面声部 Space Grotesk，数据声部 Space Mono。
enum RuneTheme {
    // MARK: - 色板（纸面）

    /// 制图蓝（主按钮、选中态、激活工具）：校对笔的蓝
    static let accent = Color(red: 0.18, green: 0.294, blue: 0.843)          // #2E4BD7
    /// 制图蓝按压态（深一档）
    static let accentPressed = Color(red: 0.141, green: 0.235, blue: 0.729) // #243CBA
    /// 主文字（蓝黑墨）：标题与正文
    static let ink = Color(red: 0.102, green: 0.106, blue: 0.118)            // #1A1B1E
    /// 主文字（同 ink，语义别名）
    static let textPrimary = Color(red: 0.102, green: 0.106, blue: 0.118)    // #1A1B1E
    /// 次要文字
    static let textSecondary = Color(red: 0.361, green: 0.373, blue: 0.4)    // #5C5F66
    /// 弱化文字
    static let textMuted = Color(red: 0.557, green: 0.569, blue: 0.596)      // #8E9198
    /// 纸面细线 / 分隔线
    static let separator = Color(red: 0.894, green: 0.894, blue: 0.871)      // #E4E4DE
    /// 页面底（冷瓷白）
    static let background = Color(red: 0.965, green: 0.965, blue: 0.953)     // #F6F6F3
    /// 卡面（纯白）
    static let card = Color.white
    /// 制图蓝 8% 底（激活底、错误底）
    static let accentDim = Color(red: 0.18, green: 0.294, blue: 0.843).opacity(0.08)

    /// 信号橘：只给录制圆点与危险操作，像车间的警示灯
    static let signal = Color(red: 0.91, green: 0.286, blue: 0.165)          // #E8492A

    // MARK: - 色板（石墨暗面）

    /// 石墨底：悬浮在画面上的深色表面（确认条、Toast、录制状态）
    static let chromeBase = Color(red: 0.114, green: 0.118, blue: 0.133)     // #1D1E22
    /// 石墨浮起面
    static let chromeElevated = Color(red: 0.149, green: 0.153, blue: 0.173) // #26272C
    /// 石墨描边
    static let chromeLine = Color(red: 0.231, green: 0.239, blue: 0.271)     // #3B3D45
    /// 石墨上的主文字
    static let chromeText = Color(red: 0.929, green: 0.933, blue: 0.941)     // #EDEEF0
    /// 石墨上的次要文字
    static let chromeMuted = Color(red: 0.651, green: 0.659, blue: 0.686)    // #A6A8AF
    /// 制图蓝·亮（石墨上的激活态、选中工具）
    static let chromeBlue = Color(red: 0.549, green: 0.608, blue: 1.0)       // #8C9BFF
    /// 制图蓝·按钮（石墨上的主按钮底色）
    static let chromeBlueFill = Color(red: 0.302, green: 0.388, blue: 0.965) // #4D63F6

    // MARK: - 尺寸

    /// 悬浮条标准高度
    static let barHeight: CGFloat = 56
    /// 悬浮条圆角
    static let barCorner: CGFloat = 14
    /// 控件圆角（按钮、输入）
    static let buttonCorner: CGFloat = 6
    /// 卡片圆角
    static let cardCorner: CGFloat = 10
    /// 图标按钮尺寸
    static let iconButtonSize: CGFloat = 38

    // MARK: - 组件样式

    /// 悬浮条底：白卡 + 细边框 + 轻投影
    static var barBackground: some View {
        RoundedRectangle(cornerRadius: barCorner, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: barCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 4)
    }

    /// 主按钮（保存/导出/开始）：制图蓝底白字
    static func primaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 13, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .fill(accent)
            )
    }

    /// 次按钮（取消/复制）：白底 + 墨色细边框
    static func secondaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 13, weight: .medium))
            .foregroundStyle(textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .fill(card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 工具图标：默认灰墨，激活 = 制图蓝图标 + 蓝 8% 底
    static func toolIcon(_ systemImage: String, active: Bool) -> some View {
        Image(systemName: systemImage)
            .font(RuneFont.swiftUI(size: 18, weight: .medium))
            .foregroundStyle(active ? accent : textSecondary)
            .frame(width: iconButtonSize, height: iconButtonSize)
            .background(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .fill(active ? accentDim : Color.clear)
            )
    }

    /// 分组竖线：功能区之间的极淡细线（1×22），自带左右各 13pt 呼吸留白
    static var groupSeparator: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Color.black.opacity(0.09))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 13)
    }

    /// 按压反馈：极轻微缩放，像系统按钮一样干脆，不弹跳。
    struct RunePressStyle: ButtonStyle {
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .opacity(configuration.isPressed ? 0.86 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.10),
                    value: configuration.isPressed
                )
        }
    }

    /// 快捷键徽章：Space Mono 数据声部 + 白底细边——校样单上的打字机读数
    static func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.mono(size: 10, weight: .medium))
            .foregroundStyle(textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 卡片底：纯白 + 1px 细边框，供各页面分区使用
    static var cardBackground: some View {
        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 校样卡片：白卡 + 细边 + 可选裁切角线（签名记号，只给重点卡用）
    static func proofCardBackground(showingCropMarks: Bool = false) -> some View {
        cardBackground
            .shadow(color: .black.opacity(0.035), radius: 8, x: 0, y: 2)
            .overlay {
                if showingCropMarks {
                    CropMarks()
                        .stroke(textMuted.opacity(0.85), lineWidth: 1)
                }
            }
    }

    /// 区块图章标签：Space Mono 小号 + 宽字距，像盖在校样上的工序章
    static func stampLabel(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.mono(size: 10, weight: .medium))
            .foregroundStyle(textMuted)
            .tracking(1.6)
    }
}

// MARK: - 裁切角线（签名记号）

/// 印刷校样四角的裁切标记：每角两段短线，分别是卡片两条边的延长线，
/// 与角留出缺口。画在 rect 边界之外，调用处需外留约 12pt 空隙。
/// 一个裁图工具，身上带着裁切标记——这是 Rune 的身份记号。
struct CropMarks: Shape {
    /// 角线臂长
    var armLength: CGFloat = 10
    /// 角线与卡片的间隙
    var gap: CGFloat = 4

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let xs: [(CGFloat, CGFloat)] = [
            (rect.minX - gap, rect.minX - gap - armLength),   // 左侧竖臂区间
            (rect.maxX + gap, rect.maxX + gap + armLength),   // 右侧竖臂区间
        ]
        let ys: [(CGFloat, CGFloat)] = [
            (rect.minY - gap, rect.minY - gap - armLength),   // 上方横臂区间
            (rect.maxY + gap, rect.maxY + gap + armLength),   // 下方横臂区间
        ]

        // 横臂：与上下边齐平的延长线
        for y in [rect.minY, rect.maxY] {
            for (x0, x1) in xs {
                path.move(to: CGPoint(x: x0, y: y))
                path.addLine(to: CGPoint(x: x1, y: y))
            }
        }
        // 竖臂：与左右边齐平的延长线
        for x in [rect.minX, rect.maxX] {
            for (y0, y1) in ys {
                path.move(to: CGPoint(x: x, y: y0))
                path.addLine(to: CGPoint(x: x, y: y1))
            }
        }
        return path
    }
}

extension View {
    /// 给内容四角加裁切角线（画在内容边界外，需要外层留出约 12pt 空隙）。
    func cropMarks(color: Color = RuneTheme.textMuted, lineWidth: CGFloat = 1) -> some View {
        overlay(
            CropMarks()
                .stroke(color, lineWidth: lineWidth)
        )
    }

    /// macOS 15+ 会给窗口工具栏自动铺一层玻璃材质，盖住自定义底色；
    /// 这里把它关掉，让纸面透出来（macOS 14 本就没有这层）。
    func toolbarBackgroundHiddenIfAvailable() -> some View {
        modifier(ToolbarBackgroundHider())
    }
}

private struct ToolbarBackgroundHider: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
