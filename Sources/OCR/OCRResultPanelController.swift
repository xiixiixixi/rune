import AppKit
import SwiftUI

/// OCR 完成后的本地结果卡：先让用户看见和修正，再决定复制。
@MainActor
final class OCRResultPanelController: NSObject, NSWindowDelegate {
    static let shared = OCRResultPanelController()

    private var panel: NSPanel?

    private override init() {}

    func show(result: OCRResult, near selection: CGRect? = nil, on preferredScreen: NSScreen? = nil) {
        dismiss()

        let content = OCRResultCardView(
            initialText: result.combinedText,
            barcodeCount: result.barcodes.count,
            onClose: { [weak self] in self?.dismiss() }
        )
        let hostingView = NSHostingView(rootView: content.runeTypography())

        let size = NSSize(width: 500, height: 350)
        let panel = OCRResultPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 260)
        panel.contentView = hostingView
        panel.delegate = self

        position(panel, near: selection, on: preferredScreen)
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

    private func position(_ panel: NSPanel, near selection: CGRect?, on preferredScreen: NSScreen?) {
        let targetScreen = preferredScreen
            ?? selection.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else { return }

        let visible = targetScreen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )

        if let selection {
            origin.x = selection.midX - size.width / 2
            origin.y = selection.minY - size.height - 12
            if origin.y < visible.minY + 12 {
                origin.y = selection.maxY + 12
            }
        }

        origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
        origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(origin)
    }
}

private struct OCRResultCardView: View {
    @State private var text: String
    @State private var didCopy = false

    let barcodeCount: Int
    let onClose: () -> Void

    init(initialText: String, barcodeCount: Int, onClose: @escaping () -> Void) {
        _text = State(initialValue: initialText)
        self.barcodeCount = barcodeCount
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            TextEditor(text: $text)
                .font(RuneFont.swiftUI(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(Color.primary.opacity(0.035))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .padding(16)
                .accessibilityLabel("识别到的文字，可编辑")

            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .tint(RuneTheme.accent)
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder")
                .font(RuneFont.swiftUI(size: 17, weight: .semibold))
                .foregroundStyle(RuneTheme.accent)
                .frame(width: 32, height: 32)
                .background(RuneTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("识别结果")
                    .font(RuneFont.swiftUI(size: 15, weight: .semibold))
                Text(barcodeCount > 0 ? "包含 \(barcodeCount) 个二维码或条码" : "可以先修正，再复制")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("完全在本机处理", systemImage: "lock.fill")
                .font(RuneFont.swiftUI(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.055), in: Capsule())

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.055), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .accessibilityLabel("关闭识别结果")
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("\(text.count) 个字符")
                .font(RuneFont.swiftUI(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            if didCopy {
                Label("已复制", systemImage: "checkmark")
                    .font(RuneFont.swiftUI(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }

            Spacer()

            Button("关闭", action: onClose)

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                didCopy = true
            } label: {
                RuneTheme.primaryButtonLabel("复制文字", systemImage: "doc.on.doc")
            }
            .buttonStyle(RuneTheme.RunePressStyle())
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
    }
}

private final class OCRResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
