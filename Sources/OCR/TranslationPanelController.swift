#if canImport(Translation)
import Translation
#endif
import AppKit
import SwiftUI

/// 截图翻译（飞书同款能力）：把识别出的文字交给系统翻译面板。
/// macOS 15+ 用 Apple Translation 框架（完全本地可选，语言可换）；
/// 更早的系统退化为提示。翻译窗口与识别卡同风格。
@MainActor
final class TranslationPanelController: NSObject, NSWindowDelegate {
    static let shared = TranslationPanelController()

    private var panel: NSPanel?

    private override init() {}

    var isAvailable: Bool {
        if #available(macOS 15, *) {
            true
        } else {
            false
        }
    }

    func show(text: String, on preferredScreen: NSScreen? = nil) {
        dismiss()

        let content = TranslationCardView(sourceText: text, onClose: { [weak self] in
            self?.dismiss()
        })
        let hostingView = NSHostingView(rootView: content.runeTypography())

        let size = NSSize(width: 520, height: 420)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "截图翻译"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 400, height: 300)
        panel.contentView = hostingView
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
    }
}

/// 面向 Apple Translation 的 SwiftUI 桥：源语言自动识别，
/// 目标语言跟随系统偏好，译文直接显示在卡片里。
@available(macOS 15, *)
private struct TranslationContentView: View {
    let sourceText: String

    @State private var configuration: TranslationSession.Configuration?
    @State private var translatedText: String?
    @State private var failureText: String?

    var body: some View {
        Group {
            if let translatedText {
                scrollableText(translatedText)
            } else if let failureText {
                scrollableText(failureText)
            } else {
                scrollableText("正在翻译…")
            }
        }
        .task {
            guard configuration == nil else { return }
            // source/target 都留空：源语言自动识别，目标语言用系统偏好
            configuration = TranslationSession.Configuration(source: nil, target: nil)
        }
        .translationTask(configuration) { value in
            // TranslationSession 在当前 SDK 下未标 Sendable，Swift 6 会拦截
            // 它进入 async 调用。会话只在这一个串行任务里使用，按 SDK 的
            // 预期用法局部解检（后续 SDK 标注 Sendable 后可去掉）。
            nonisolated(unsafe) let session = value
            do {
                let response = try await session.translate(sourceText)
                await MainActor.run {
                    translatedText = response.targetText
                }
            } catch {
                let message = "翻译没有完成：\(error.localizedDescription)"
                await MainActor.run {
                    failureText = message
                }
            }
        }
    }

    private func scrollableText(_ value: String) -> some View {
        ScrollView(.vertical) {
            Text(value)
                .font(RuneFont.swiftUI(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
    }
}

private struct TranslationCardView: View {
    let sourceText: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header

            if #available(macOS 15, *) {
                TranslationContentView(sourceText: sourceText)
                    .background(
                        RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                            .fill(RuneTheme.workspace.opacity(0.88))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
                    .accessibilityLabel("翻译结果")
            } else {
                Text("截图翻译需要 macOS 15 或更高版本。\n可以在「系统设置 › 通用 › 语言与地区」里添加语言后重试。")
                    .font(RuneFont.swiftUI(size: 12))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                            .fill(RuneTheme.workspace.opacity(0.88))
                    )
            }

            footer
        }
        .padding(14)
        .runeGlassSurface(cornerRadius: RuneTheme.cardCorner, elevation: .floating)
        .tint(RuneTheme.textPrimary)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            RuneOpticalIconPlate(systemImage: "character.book.closed", size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("截图翻译")
                    .font(RuneFont.swiftUI(size: 15, weight: .medium))
                Text("源文字来自识别结果，翻译在系统面板完成")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(RuneTheme.textSecondary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .foregroundStyle(RuneTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .accessibilityLabel("关闭翻译")
        }
        .frame(height: 46)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(sourceText, forType: .string)
            } label: {
                RuneTheme.secondaryButtonLabel("复制原文")
            }
            .buttonStyle(RuneTheme.RunePressStyle())

            Spacer()

            Button(action: onClose) {
                RuneTheme.primaryButtonLabel("完成", systemImage: "checkmark")
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .frame(height: 44)
    }
}
