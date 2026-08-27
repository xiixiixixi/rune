import SwiftUI

/// Rune 设计系统——「取景玻璃 Viewfinder Glass」。
///
/// 内容始终清晰，玻璃只承载导航、工具和临时操作。颜色、文字和控件跟随
/// macOS 的明暗外观与辅助功能；macOS 26 使用系统 Liquid Glass（液态玻璃），
/// macOS 14–15 使用原生 Material（材质）回退。裁切角线仍是 Rune 的产品签名，
/// 但只用于需要强调“取景/裁剪”的关键表面。
enum RuneTheme {
    // MARK: - 系统动态色

    static let accent = Color(nsColor: .controlAccentColor)
    static let accentFill = Color(nsColor: .controlAccentColor)
    static let accentPressed = Color(nsColor: .controlAccentColor).opacity(0.82)
    static let ink = Color.primary
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textMuted = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor).opacity(0.72)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let accentDim = Color(nsColor: .controlAccentColor).opacity(0.12)

    static let nsBackground = NSColor.windowBackgroundColor
    static let nsAccent = NSColor.controlAccentColor
    static let signal = Color(nsColor: .systemRed)

    // 旧命名作为语义兼容层保留；颜色已统一为系统动态色。
    static let paperBackground = Color(nsColor: .windowBackgroundColor)
    static let paperCard = Color(nsColor: .controlBackgroundColor)
    static let paperInk = Color.primary
    static let paperTextSecondary = Color.secondary
    static let paperTextMuted = Color(nsColor: .tertiaryLabelColor)
    static let paperSeparator = Color(nsColor: .separatorColor).opacity(0.72)
    static let paperControl = Color(nsColor: .controlBackgroundColor)
    static let paperAccent = Color(nsColor: .controlAccentColor)
    static let annotationAccent = Color(nsColor: .controlAccentColor)
    static let editorWorkspace = Color(nsColor: .underPageBackgroundColor)

    static let nsPaperBackground = NSColor.windowBackgroundColor
    static let nsPaperAccent = NSColor.controlAccentColor

    // 悬浮表面使用高对比动态色，真正的透明材质由 runeGlassSurface 提供。
    static let chromeBase = Color(nsColor: .windowBackgroundColor).opacity(0.92)
    static let chromeElevated = Color(nsColor: .controlBackgroundColor).opacity(0.72)
    static let chromeLine = Color(nsColor: .separatorColor).opacity(0.68)
    static let chromeText = Color.primary
    static let chromeMuted = Color.secondary
    static let chromeBlue = Color(nsColor: .controlAccentColor)
    static let chromeBlueFill = Color(nsColor: .controlAccentColor)

    // MARK: - 尺寸

    /// 悬浮条标准高度
    static let barHeight: CGFloat = 56
    /// 悬浮条圆角
    static let barCorner: CGFloat = 18
    /// 控件圆角（按钮、输入）
    static let buttonCorner: CGFloat = 8
    /// 卡片圆角
    static let cardCorner: CGFloat = 12
    /// 图标按钮尺寸
    static let iconButtonSize: CGFloat = 38

    // MARK: - 组件样式

    /// 悬浮条底：macOS 26 原生玻璃，旧系统使用 Material 回退。
    static var barBackground: some View {
        RuneGlassBackground(cornerRadius: barCorner, elevation: .floating)
    }

    /// 主按钮（保存/导出/开始）：系统强调色底、白字。
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
                    .fill(chromeElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: buttonCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 工具图标：默认使用次要文字色，激活时跟随系统强调色。
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

    /// 快捷键徽章：SF Mono（系统等宽字体）配合轻量浮面和细边。
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

    /// 卡片底：系统控制背景 + 1px 分隔线，供各页面分区使用。
    static var cardBackground: some View {
        RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
            .fill(card)
            .overlay(
                RoundedRectangle(cornerRadius: cardCorner, style: .continuous)
                    .strokeBorder(separator, lineWidth: 1)
            )
    }

    /// 面板卡：浮面 + 分隔线 + 可选裁切角线（签名记号，只给重点卡用）。
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

    /// 区块标签。保留旧 API，但不再额外拉开字距。
    static func stampLabel(_ text: String) -> some View {
        Text(text)
            .font(RuneFont.mono(size: 10, weight: .medium))
            .foregroundStyle(textMuted)
    }
}

// MARK: - 玻璃表面

enum RuneGlassElevation {
    case embedded
    case floating

    var shadowOpacity: Double { self == .floating ? 0.16 : 0.05 }
    var shadowRadius: CGFloat { self == .floating ? 22 : 8 }
    var shadowY: CGFloat { self == .floating ? 8 : 2 }
}

/// 单一玻璃实现入口，避免各页面自行拼透明度和模糊。
struct RuneGlassBackground: View {
    let cornerRadius: CGFloat
    var tint: Color? = nil
    var interactive = false
    var elevation: RuneGlassElevation = .embedded

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Group {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(
                        Glass.regular.tint(tint).interactive(interactive),
                        in: shape
                    )
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay(
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        )
        .overlay(
            shape.strokeBorder(RuneTheme.separator.opacity(0.55), lineWidth: 0.5)
        )
        .shadow(
            color: .black.opacity(elevation.shadowOpacity),
            radius: elevation.shadowRadius,
            y: elevation.shadowY
        )
    }
}

private struct RuneGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool
    let elevation: RuneGlassElevation

    func body(content: Content) -> some View {
        content.background {
            RuneGlassBackground(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                elevation: elevation
            )
        }
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
    /// 为导航、工具和弹层添加统一系统玻璃。不要用于长文本内容卡。
    func runeGlassSurface(
        cornerRadius: CGFloat = RuneTheme.cardCorner,
        tint: Color? = nil,
        interactive: Bool = false,
        elevation: RuneGlassElevation = .embedded
    ) -> some View {
        modifier(
            RuneGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                elevation: elevation
            )
        )
    }

    /// 给内容四角加裁切角线（画在内容边界外，需要外层留出约 12pt 空隙）。
    func cropMarks(color: Color = RuneTheme.textMuted, lineWidth: CGFloat = 1) -> some View {
        overlay(
            CropMarks()
                .stroke(color, lineWidth: lineWidth)
        )
    }

    /// 旧调用兼容层。新的设计保留系统工具栏材质，不再隐藏它。
    func toolbarBackgroundHiddenIfAvailable() -> some View {
        self
    }
}
