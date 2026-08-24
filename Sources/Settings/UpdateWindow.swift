import AppKit
import SwiftUI

/// 自动更新弹窗：检查到新版本后弹出，点一次"立即更新"，
/// 之后下载、校验、替换、重启全部自动完成。
@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    private init() {}

    func present(_ update: RuneUpdate, currentVersion: String, on screen: NSScreen? = nil) {
        if let window {
            window.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = UpdateWindowView(update: update, currentVersion: currentVersion)
        let hosting = NSHostingView(rootView: contentView.runeTypography())

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 380, height: 480)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "软件更新"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 更新弹窗内容

struct UpdateWindowView: View {
    let update: RuneUpdate
    let currentVersion: String

    @State private var phase: Phase = .confirming
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    private enum Phase {
        case confirming
        case downloading
        case installing
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // 应用图标（茄子）
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(update.version)")
                        .font(RuneFont.swiftUI(size: 17, weight: .bold))

                    Text("当前版本 \(currentVersion) · 更新自动完成，无需手动安装")
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
            .padding(.bottom, 16)

            Divider()

            ScrollView(showsIndicators: true) {
                Text(update.notes.isEmpty ? "问题修复与体验优化。" : update.notes)
                    .font(RuneFont.swiftUI(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }

            Divider()

            if phase == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text("正在下载 \(Int(progress * 100))%…")
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 14)
            } else if phase == .installing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装，完成后自动重启…")
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
            } else if phase == .failed, let errorMessage {
                Text(errorMessage)
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.top, 14)
            }

            HStack {
                if update.downloadURL == nil {
                    Button("前往手动下载") {
                        NSWorkspace.shared.open(update.releasePageURL)
                    }
                }

                Spacer()

                if phase == .confirming || phase == .failed {
                    Button("以后再说") {
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(phase == .failed ? "重试" : "立即更新") {
                        startUpdate()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(RuneTheme.accent)
                    .disabled(update.downloadURL == nil)
                }
            }
            .padding(.top, 14)
        }
        .padding(20)
        .frame(width: 380, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func startUpdate() {
        errorMessage = nil
        phase = .downloading
        progress = 0

        Task {
            do {
                let zipURL = try await UpdateService.download(update) { value in
                    progress = value
                }
                phase = .installing
                try UpdateService.installAndRelaunch(zipURL: zipURL)
            } catch {
                phase = .failed
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "更新失败，请稍后再试。"
            }
        }
    }
}
