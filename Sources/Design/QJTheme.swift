import SwiftUI

/// 轻截设计系统（红白配色 · 悬浮条优先）。
///
/// 规范见 docs/交互设计.md：
/// - 白为主、红点缀：红色只用于激活态和主按钮，一处界面 ≤2 处红
/// - 悬浮条：白色磨砂、圆角 14、高 48、轻投影
enum QJTheme {
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
    static let barHeight: CGFloat = 48
    /// 悬浮条圆角
    static let barCorner: CGFloat = 14
    /// 图标按钮尺寸
    static let iconButtonSize: CGFloat = 32

    /// 悬浮条底：白磨砂 + 圆角 + 细边 + 轻投影
    static var barBackground: some View {
        RoundedRectangle(cornerRadius: barCorner, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: barCorner, style: .continuous)
                    .strokeBorder(separator.opacity(0.6), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 5)
    }

    /// 主按钮（保存/停止/开始）：红底白字胶囊，一个悬浮条只放一个
    static func primaryButtonLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(accent))
    }

    /// 次按钮（取消/复制等）：灰字，hover 浅底
    static func secondaryButtonLabel(_ text: String, systemImage: String? = nil) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(textPrimary)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Capsule().fill(Color.clear))
    }

    /// 工具图标按钮：默认灰，hover 黑+浅底，激活红
    static func toolIcon(_ systemImage: String, active: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(active ? accent : textSecondary)
            .frame(width: iconButtonSize, height: iconButtonSize)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? accent.opacity(0.12) : Color.clear)
            )
    }

    /// 快捷键徽章：灰字白底小胶囊
    static func shortcutBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.7)))
            .overlay(Capsule().strokeBorder(separator, lineWidth: 0.5))
    }
}
