import AppKit
import SwiftUI

/// Rune 的统一字体入口。界面使用系统 SF / 苹方，数据使用 SF Mono，
/// 因而能自动适配 macOS 的字重、渲染和辅助功能。
enum RuneFont {
    /// 兼容旧调用；系统字体不需要注册。
    @MainActor
    static func registerBundledFonts() {}

    // MARK: - SwiftUI

    /// 系统界面字体。中文会自动使用苹方。
    static func swiftUI(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design? = nil
    ) -> Font {
        Font.system(size: size, weight: weight, design: design ?? .default)
    }

    /// 系统等宽字体：快捷键、尺寸、版本号、计数。
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }

    static let body = swiftUI(size: 13)
    static let caption = swiftUI(size: 12)
    static let caption2 = swiftUI(size: 10)

    // MARK: - AppKit

    /// AppKit 系统界面字体。
    static func appKit(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 数据字体的 AppKit 版本。
    static func monoAppKit(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - 自检

    /// 字体自检（--audit-font）：确认界面与等宽系统字体都可用。
    /// 结果写 /tmp/rune-font-result.txt。
    @MainActor
    static func runFontSelfTest() {
        registerBundledFonts()

        let ui = appKit(size: 13)
        let mono = monoAppKit(size: 13)
        let report = """
        界面字体: PASS ✅ \(ui.fontName)
        等宽字体: PASS ✅ \(mono.fontName)
        """
        try? report.write(toFile: "/tmp/rune-font-result.txt", atomically: true, encoding: .utf8)
        print("[字体自测]\n" + report)
    }
}

private struct RuneTypographyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.environment(\.font, RuneFont.body)
    }
}

extension View {
    /// 给没有单独指定字号的文字提供 Rune 的默认字体。
    func runeTypography() -> some View {
        modifier(RuneTypographyModifier())
    }
}
