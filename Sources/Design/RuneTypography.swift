import AppKit
import CoreText
import SwiftUI

/// Rune 的统一字体入口。
///
/// 与 Mana 保持一致：界面优先使用 Space Mono，只有字体未能加载时才回退到
/// macOS 自带的等宽字体。Space Mono 本身没有中文字形，中文会由系统自动补齐。
enum RuneFont {
    private static let familyName = "Space Mono"
    private static let regularPostScriptName = "SpaceMono-Regular"
    private static let boldPostScriptName = "SpaceMono-Bold"

    @MainActor private static var didRegisterBundledFonts = false

    /// 在任何 SwiftUI / AppKit 界面创建前注册随应用附带的字体。
    @MainActor
    static func registerBundledFonts() {
        guard !didRegisterBundledFonts else { return }
        didRegisterBundledFonts = true

        for resource in [regularPostScriptName, boldPostScriptName] {
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

    /// SwiftUI 字体。`design` 参数保留是为了方便替换原有系统字体调用；
    /// Rune 的界面设计始终使用 Space Mono。
    static func swiftUI(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design _: Font.Design? = nil
    ) -> Font {
        Font.custom(familyName, fixedSize: size).weight(weight)
    }

    static let body = swiftUI(size: 13)
    static let caption = swiftUI(size: 12)
    static let caption2 = swiftUI(size: 10)

    /// AppKit 字体。Mana 只使用 400 / 700 两档，因此半粗以上映射到 Bold。
    static func appKit(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let postScriptName = weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? boldPostScriptName
            : regularPostScriptName
        return NSFont(name: postScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// 字体自检（--audit-font）：确认 Space Mono 已注册且实际取到的是它而非回退。
    /// 结果写 /tmp/rune-font-result.txt。
    @MainActor
    static func runFontSelfTest() {
        registerBundledFonts()

        // NSFont 按名字能取到，即说明注册成功且实际可用
        let regular = appKit(size: 13)
        let bold = appKit(size: 13, weight: .bold)
        let report = """
        常规: \(regular.fontName == regularPostScriptName ? "PASS ✅" : "FAIL ❌") \(regular.fontName)
        粗体: \(bold.fontName == boldPostScriptName ? "PASS ✅" : "FAIL ❌") \(bold.fontName)
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
