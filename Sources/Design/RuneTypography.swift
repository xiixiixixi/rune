import AppKit
import CoreText
import SwiftUI

/// Rune 的统一字体入口（校样台设计系统）。
///
/// 两个声部：
/// - **界面声部 Space Grotesk**：所有标题、按钮、正文——有性格的几何无衬线，
///   与 Space Mono 同门，保留极客血统但更适合阅读。中文自动回退苹方。
/// - **数据声部 Space Mono**：快捷键、尺寸、版本号、计数等"机器读数"，
///   等宽让数字对齐、可校对，像校样单上的打字机数据。
enum RuneFont {
    // MARK: - 家族

    private static let uiFamilyName = "Space Grotesk"
    private static let uiRegular = "SpaceGrotesk-Regular"
    private static let uiMedium = "SpaceGrotesk-Medium"
    private static let uiBold = "SpaceGrotesk-Bold"

    private static let monoFamilyName = "Space Mono"
    private static let monoRegular = "SpaceMono-Regular"
    private static let monoBold = "SpaceMono-Bold"

    @MainActor private static var didRegisterBundledFonts = false

    /// 在任何 SwiftUI / AppKit 界面创建前注册随应用附带的字体。
    @MainActor
    static func registerBundledFonts() {
        guard !didRegisterBundledFonts else { return }
        didRegisterBundledFonts = true

        let resources = [
            uiRegular, uiMedium, uiBold,
            monoRegular, monoBold,
        ]
        for resource in resources {
            guard let url = Bundle.main.url(
                forResource: resource,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                assertionFailure("Rune 字体资源缺失：\(resource).ttf")
                continue
            }

            var registrationError: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(
                url as CFURL,
                .process,
                &registrationError
            )
            if !registered, let error = registrationError?.takeRetainedValue() {
                // 已注册也会返回 false；只在调试日志中保留信息，不阻断启动。
                print("Rune 字体注册提示：\(error)")
            }
        }
    }

    // MARK: - SwiftUI

    /// 界面字体（Space Grotesk）。`design` 参数保留兼容旧调用，统一忽略。
    static func swiftUI(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design _: Font.Design? = nil
    ) -> Font {
        Font.custom(uiFamilyName, fixedSize: size).weight(weight)
    }

    /// 数据字体（Space Mono）：快捷键、尺寸、版本号、计数。
    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(monoFamilyName, fixedSize: size).weight(weight)
    }

    static let body = swiftUI(size: 13)
    static let caption = swiftUI(size: 12)
    static let caption2 = swiftUI(size: 10)

    // MARK: - AppKit

    /// 界面字体。三档静态字重：≥semibold 用 Bold，≥medium 用 Medium，其余 Regular。
    static func appKit(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let postScriptName: String
        if weight.rawValue >= NSFont.Weight.semibold.rawValue {
            postScriptName = uiBold
        } else if weight.rawValue >= NSFont.Weight.medium.rawValue {
            postScriptName = uiMedium
        } else {
            postScriptName = uiRegular
        }
        return NSFont(name: postScriptName, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// 数据字体的 AppKit 版本。
    static func monoAppKit(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let postScriptName = weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? monoBold
            : monoRegular
        return NSFont(name: postScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    // MARK: - 自检

    /// 字体自检（--audit-font）：确认两个家族都已注册且实际取到而非回退。
    /// 结果写 /tmp/rune-font-result.txt。
    @MainActor
    static func runFontSelfTest() {
        registerBundledFonts()

        let ui = appKit(size: 13)
        let uiMediumFont = appKit(size: 13, weight: .medium)
        let uiBoldFont = appKit(size: 13, weight: .bold)
        let mono = monoAppKit(size: 13)
        let report = """
        界面 Regular: \(ui.fontName == uiRegular ? "PASS ✅" : "FAIL ❌") \(ui.fontName)
        界面 Medium:  \(uiMediumFont.fontName == uiMedium ? "PASS ✅" : "FAIL ❌") \(uiMediumFont.fontName)
        界面 Bold:    \(uiBoldFont.fontName == uiBold ? "PASS ✅" : "FAIL ❌") \(uiBoldFont.fontName)
        数据 Mono:    \(mono.fontName == monoRegular ? "PASS ✅" : "FAIL ❌") \(mono.fontName)
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
