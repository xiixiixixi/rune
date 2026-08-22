import SwiftUI

/// Rune设计系统（红白配色 · 悬浮条优先）。
///
/// 规范见 docs/交互设计.md：
/// - 白为主、红点缀：红色只用于激活态和主按钮，一处界面 ≤2 处红
/// - 悬浮条：白色磨砂、圆角 14、高 48、轻投影
enum RuneTheme {
    // MARK: - 色板

    /// 点缀红（主强调）：激活态、主按钮、选区边框、进度
    static let accent = Color(red: 1.0, green: 0.231, blue: 0.189)   // #FF3B30
    /// 红 hover 深一档
    static let accentPressed = Color(red: 0.898, green: 0.204, blue: 0.165)  // #E5342A
    /// 主文字（近黑）
    static let textPrimary = Color(red: 0.114, green: 0.114, blue: 0.122)    // #1D1D1F
    /// 次要文字（灰）
    static let textSecondary = Color(red: 0.525, green: 0.525, blue: 0.545)  // #86868B
    /// 分隔线
    static let separator = Color(red: 0.898, green: 0.898, blue: 0.918)      // #E5E5EA
    /// 页面底（苹果灰白）
    static let background = Color(red: 0.961, green: 0.961, blue: 0.969)     // #F5F5F7

    // MARK: - 悬浮条样式

    /// 悬浮条标准高度
    static let barHeight: CGFloat = 56
    /// 悬浮条圆角
    static let barCorner: CGFloat = 16
    /// 图标按钮尺寸
    static let iconButtonSize: CGFloat = 38

    /// 悬浮条底：白磨砂 + 圆角 + 细边 + 分层投影
    static var barBackground: some View {
        RoundedRectangle(cornerRadius: barCorner, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: barCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.10), radius: 24, x: 0, y: 8)
            .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 1)
    }

    /// 主按钮（保存）：红底白字胶囊 + 红色微投影（唯一红色块）。图标可选。
    static func primaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(RuneFont.swiftUI(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                Capsule()
                    .fill(accent)
                    .shadow(color: accent.opacity(0.35), radius: 8, x: 0, y: 2)
            )
    }

    /// 次按钮（取消/复制/贴图）：深灰字胶囊，描边极淡
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
        .frame(height: 34)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.55))
                .overlay(Capsule().strokeBorder(separator, lineWidth: 0.5))
        )
    }

    /// 工具图标：18pt medium；默认石墨灰，激活=红图标+红 10% 圆角底
    static func toolIcon(_ systemImage: String, active: Bool) -> some View {
        Image(systemName: systemImage)
            .font(RuneFont.swiftUI(size: 18, weight: .medium))
            .foregroundStyle(active ? accent : Color(red: 0.35, green: 0.35, blue: 0.37))
            .frame(width: iconButtonSize, height: iconButtonSize)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? accent.opacity(0.10) : Color.clear)
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

    /// 快捷键徽章：灰字白底小胶囊
    static func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.swiftUI(size: 11, weight: .medium))
            .foregroundStyle(textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.7)))
            .overlay(Capsule().strokeBorder(separator, lineWidth: 0.5))
    }
}
