import SwiftUI

/// Rune 设计系统（与 Mana 同源：极客终端风）。
///
/// 从 mana 界面原样迁移的 token：
/// - 暖白底 #FAFAFA + 纯白卡片 + 1px #E5E5E5 细边框，小圆角（3-10pt）
/// - 近黑 #111 主文字、#666 次要、#999 弱化
/// - 橙红 #FF3B00 只做激活态与点缀；主按钮是黑底白字（墨色反转）
/// - Space Mono 等宽字体（见 RuneFont）
enum RuneTheme {
    // MARK: - 色板（与 mana :root 一一对应）

    /// 点缀橙红（激活态、选中态、错误提示）：mana --accent
    static let accent = Color(red: 1.0, green: 0.231, blue: 0.0)        // #FF3B00
    /// hover 深一档
    static let accentPressed = Color(red: 0.878, green: 0.204, blue: 0.0)  // #E03400
    /// 主按钮墨色（黑底白字）：mana --ink
    static let ink = Color(red: 0.067, green: 0.067, blue: 0.067)       // #111111
    /// 主文字（近黑）：mana --ink
    static let textPrimary = Color(red: 0.067, green: 0.067, blue: 0.067)   // #111111
    /// 次要文字：mana --gray
    static let textSecondary = Color(red: 0.4, green: 0.4, blue: 0.4)       // #666666
    /// 弱化文字：mana --muted
    static let textMuted = Color(red: 0.6, green: 0.6, blue: 0.6)           // #999999
    /// 细边框 / 分隔线：mana --border
    static let separator = Color(red: 0.898, green: 0.898, blue: 0.898)     // #E5E5E5
    /// 页面底（暖白）：mana --bg
    static let background = Color(red: 0.98, green: 0.98, blue: 0.98)       // #FAFAFA
    /// 卡片底（纯白）：mana --card
    static let card = Color.white
    /// 强调色的 8% 底（错误提示条、激活底）：mana --accent-dim
    static let accentDim = Color(red: 1.0, green: 0.231, blue: 0.0).opacity(0.08)

    // MARK: - 尺寸

    /// 悬浮条标准高度
    static let barHeight: CGFloat = 56
    /// 悬浮条圆角（mana 的窗体圆角 10）
    static let barCorner: CGFloat = 10
    /// 按钮/卡片小圆角（mana .btn 为 3px）
    static let buttonCorner: CGFloat = 3
    /// 图标按钮尺寸
    static let iconButtonSize: CGFloat = 38

    // MARK: - 组件样式

    /// 悬浮条底：纯白卡 + 细边框 + 轻投影（mana 卡片风）
    static var barBackground: some View {
        RoundedRectangle(cornerRadius: barCorner, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: barCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
    }

    /// 主按钮（保存/导出）：墨色底白字，mana 的 btn-primary（黑底白字小方角）
    static func primaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 13, weight: .bold))
            .foregroundStyle(Color(red: 0.98, green: 0.98, blue: 0.98))
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .fill(ink)
            )
    }

    /// 次按钮（取消/复制）：透明底 + 1px 细边框 + 小方角，mana 的 .btn
    static func secondaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 13, weight: .bold))
            .foregroundStyle(textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                            .strokeBorder(separator, lineWidth: 1)
                    )
            )
    }

    /// 工具图标：18pt medium；默认灰墨，激活=橙红图标 + 橙红 8% 小圆角底
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

    /// 快捷键徽章：白底细边小方角
    static func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.swiftUI(size: 11, weight: .medium))
            .foregroundStyle(textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .fill(Color.white.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 卡片底：纯白 + 1px 细边框（mana .card），供各页面分区使用
    static var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }
}
