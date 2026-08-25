import SwiftUI

/// Rune 设计系统——「石墨仪器 Graphite Instrument」。
///
/// 概念：Rune 是一台仪器，不是一叠纸。整机是截后确认条那种石墨机身：
/// - **机身** 石墨 #1D1E22 是所有窗口与页面的底，发丝机线 #3B3D45 分割功能区；
/// - **瓷白墨** #EDEEF0 承载文字，次墨与弱墨递减，像刻度盘上的刻字；
/// - **瓷蓝** 唯一主色——仪器的指示灯：文字与激活态用亮瓷蓝 #8C9BFF，
///   主按钮底用饱和蓝 #4D63F6（永远配白字）；
/// - **信号橘** 只出现在录制与危险操作上，是警示灯；
/// - **裁切角线**（CropMarks）是签名记号：一个裁图工具，身上带着裁切标记；
/// - 应用内唯一的"纸"是用户的截图本身——深色机身让内容最跳。
///
/// 整机钉在深色外观（applyAppearance 恒定 darkAqua）：仪器只有一种机身，
/// 系统控件与石墨面板永远同声部，外观串色事故从结构上不存在。
///
/// 字体见 RuneFont：界面声部 Space Grotesk，数据声部 Space Mono。
enum RuneTheme {
    // MARK: - 色板（石墨·单一声部）

    /// 瓷蓝（选中态、激活工具、强调文字）：仪器指示灯的亮色
    static let accent = Color(red: 0.549, green: 0.608, blue: 1.0)           // #8C9BFF
    /// 主按钮底色：饱和蓝 + 白字，对比度 ≥4.7:1
    static let accentFill = Color(red: 0.302, green: 0.388, blue: 0.965)     // #4D63F6
    /// 主按钮按压态（深一档）
    static let accentPressed = Color(red: 0.239, green: 0.318, blue: 0.91)   // #3D51E8
    /// 主文字（瓷白墨）
    static let ink = Color(red: 0.929, green: 0.933, blue: 0.941)            // #EDEEF0
    /// 主文字（同 ink，语义别名）
    static let textPrimary = ink
    /// 次要文字（次墨）
    static let textSecondary = Color(red: 0.651, green: 0.659, blue: 0.686)  // #A6A8AF
    /// 弱化文字（弱墨）
    static let textMuted = Color(red: 0.486, green: 0.498, blue: 0.529)      // #7C7F87
    /// 细线 / 分隔线（机线）
    static let separator = Color(red: 0.231, green: 0.239, blue: 0.271)      // #3B3D45
    /// 页面底（机身）
    static let background = Color(red: 0.114, green: 0.118, blue: 0.133)     // #1D1E22
    /// 卡面（浮起面）
    static let card = Color(red: 0.149, green: 0.153, blue: 0.173)           // #26272C
    /// 瓷蓝淡底（激活底、错误底）
    static let accentDim = Color(red: 0.549, green: 0.608, blue: 1.0).opacity(0.14)

    /// 窗口底色的原生句柄：NSWindow.backgroundColor 直接用这份。
    static let nsBackground = NSColor(
        calibratedRed: 0.114, green: 0.118, blue: 0.133, alpha: 1
    )
    /// 强调色的原生句柄（NSView 层 contentTintColor / 手绘用）
    static let nsAccent = NSColor(
        calibratedRed: 0.549, green: 0.608, blue: 1.0, alpha: 1
    )

    /// 信号橘：只给录制圆点与危险操作，仪器的警示灯
    static let signal = Color(red: 0.91, green: 0.286, blue: 0.165)          // #E8492A

    // MARK: - 暖白纸面（设置、编辑器属性面板）

    /// 设置与属性面板不再套用整机石墨色。纸面只承载控制，截图内容仍是主角。
    static let paperBackground = Color(red: 0.973, green: 0.969, blue: 0.953) // #F8F7F3
    static let paperCard = Color.white
    static let paperInk = Color(red: 0.075, green: 0.075, blue: 0.071)        // #131312
    static let paperTextSecondary = Color(red: 0.31, green: 0.306, blue: 0.286)
    static let paperTextMuted = Color(red: 0.55, green: 0.537, blue: 0.50)
    static let paperSeparator = Color(red: 0.89, green: 0.878, blue: 0.835)
    static let paperControl = Color(red: 0.94, green: 0.933, blue: 0.91)
    static let paperAccent = paperInk
    static let annotationAccent = Color(red: 1.0, green: 0.35, blue: 0.27)
    static let editorWorkspace = Color(red: 0.075, green: 0.082, blue: 0.094)

    static let nsPaperBackground = NSColor(
        calibratedRed: 0.973, green: 0.969, blue: 0.953, alpha: 1
    )
    static let nsPaperAccent = NSColor(
        calibratedRed: 0.075, green: 0.075, blue: 0.071, alpha: 1
    )

    // MARK: - 石墨家族别名

    /// 以下别名保留给"悬浮在画面上"的表面（确认条、Toast、录制状态条）。
    /// 重新设计后全机统一石墨声部，别名与主色板同值，
    /// 保留命名是为了让悬浮面代码继续读出"这是压在画面上的面"。
    static let chromeBase = Color(red: 0.114, green: 0.118, blue: 0.133)      // #1D1E22
    static let chromeElevated = Color(red: 0.149, green: 0.153, blue: 0.173)  // #26272C
    static let chromeLine = Color(red: 0.231, green: 0.239, blue: 0.271)      // #3B3D45
    static let chromeText = Color(red: 0.929, green: 0.933, blue: 0.941)      // #EDEEF0
    static let chromeMuted = Color(red: 0.651, green: 0.659, blue: 0.686)     // #A6A8AF
    static let chromeBlue = Color(red: 0.549, green: 0.608, blue: 1.0)        // #8C9BFF
    static let chromeBlueFill = Color(red: 0.302, green: 0.388, blue: 0.965)  // #4D63F6

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

    /// 悬浮条底：石墨浮面 + 机线细边 + 轻投影
    static var barBackground: some View {
        RoundedRectangle(cornerRadius: barCorner, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: barCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.07), radius: 14, x: 0, y: 4)
    }

    /// 主按钮（保存/导出/开始）：制图蓝底白字（accentFill 两班都保证白字可读）
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
                    .fill(accentFill)
            )
    }

    /// 次按钮（取消/复制）：浮面 + 机线细边
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

    /// 工具图标：默认次墨，激活 = 瓷蓝图标 + 瓷蓝淡底
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
            .fill(ink.opacity(0.09))
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

    /// 快捷键徽章：Space Mono 数据声部 + 浮面细边——仪器铭牌上的打字机读数
    static func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.mono(size: 10, weight: .medium))
            .foregroundStyle(textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(card.opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 卡片底：石墨浮面 + 1px 机线，供各页面分区使用
    static var cardBackground: some View {
        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 面板卡：浮面 + 机线 + 可选裁切角线（签名记号，只给重点卡用）
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

    /// 区块图章标签：Space Mono 小号 + 宽字距，像铭刻在面板上的工序章
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
