import AppKit
import SwiftUI

/// 自动更新弹窗：检查到新版本后弹出，点一次"立即更新"，
/// 之后下载、校验、替换、重启全部自动完成。
@MainActor
final class UpdateWindowController: NSObject {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func present(_ update: RuneUpdate, currentVersion: String, on screen: NSScreen? = nil) {
        if let window {
            window.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = UpdateWindowView(update: update, currentVersion: currentVersion)
        let hosting = NSHostingView(rootView: contentView.runeTypography())

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 400, height: 380)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "软件更新"
        window.contentView = hosting
        window.titlebarAppearsTransparent = true
        window.backgroundColor = RuneTheme.nsBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 关窗（"以后再说"或标题栏关闭）后清掉引用，
/// 这样下一次检查到更新的版本时能弹出新内容的窗口，
/// 而不是把旧窗口原样再摆到前面。
extension UpdateWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - 更新弹窗内容

struct UpdateWindowView: View {
    let update: RuneUpdate
    let currentVersion: String

    @State private var phase: Phase = .confirming
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var recoveryAction: RecoveryAction?

    private enum Phase {
        case confirming
        case downloading
        case installing
        case switchingToInstalledApplication
        case failed
    }

    private enum RecoveryAction {
        case openInstalledApplication
        case openReleasePage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                // 应用图标（茄子）
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: RuneTheme.plateCorner, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("发现新版本 \(update.version)")
                        .font(RuneFont.swiftUI(size: 17, weight: .bold))

                    Text("当前版本 \(currentVersion) · 更新自动完成，无需手动安装")
                        .font(RuneFont.mono(size: 10))
                        .foregroundStyle(RuneTheme.textSecondary)
                        .lineSpacing(2)
                }
            }
            .padding(.bottom, 2)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("本次更新", systemImage: "sparkles")
                        .font(RuneFont.swiftUI(size: 11, weight: .semibold))
                        .foregroundStyle(RuneTheme.textSecondary)
                    Text(update.notes.isEmpty ? "问题修复与体验优化。" : update.notes)
                        .font(RuneFont.swiftUI(size: 11.5))
                        .foregroundStyle(.primary.opacity(0.86))
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
            .frame(maxHeight: 184)
            .background(RuneCardBackground(cornerRadius: RuneTheme.plateCorner))

            if phase == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text("正在下载 \(Int(progress * 100))%…")
                        .font(RuneFont.mono(size: 10))
                        .foregroundStyle(RuneTheme.textSecondary)
                }
            } else if phase == .installing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装，完成后自动重启…")
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if phase == .switchingToInstalledApplication {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在打开应用程序中的 Rune…")
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if phase == .failed, let errorMessage {
                Text(errorMessage)
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(RuneTheme.signal.opacity(0.9))
            }

            HStack {
                if update.downloadURL == nil {
                    Button {
                        NSWorkspace.shared.open(update.releasePageURL)
                    } label: {
                        RuneTheme.secondaryButtonLabel("前往手动下载")
                    }
                    .buttonStyle(RuneTheme.RunePressStyle())
                }

                Spacer()

                if phase == .confirming || phase == .failed {
                    Button {
                        NSApp.keyWindow?.close()
                    } label: {
                        RuneTheme.secondaryButtonLabel("以后再说")
                    }
                    .buttonStyle(RuneTheme.RunePressStyle())
                    .keyboardShortcut(.cancelAction)

                    Button {
                        if recoveryAction == .openInstalledApplication {
                            openInstalledApplication()
                        } else if recoveryAction == .openReleasePage {
                            NSWorkspace.shared.open(update.releasePageURL)
                        } else {
                            startUpdate()
                        }
                    } label: {
                        RuneTheme.primaryButtonLabel(primaryButtonTitle)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(RuneTheme.RunePressStyle())
                    .disabled(recoveryAction == nil && update.downloadURL == nil)
                }
            }
        }
        .padding(20)
        .frame(width: 400, height: 380)
        .background(RuneAmbientBackdrop())
        .preferredColorScheme(.dark)
    }

    private var primaryButtonTitle: String {
        if recoveryAction == .openInstalledApplication {
            return "打开正式版"
        }
        if recoveryAction == .openReleasePage {
            return "手动下载"
        }
        return phase == .failed ? "重试" : "立即更新"
    }

    private func startUpdate() {
        errorMessage = nil
        recoveryAction = nil
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
                if let updateError = error as? RuneUpdateError,
                   case .devBuildNotSupported = updateError {
                    if let installed = UpdateService.installedApplication() {
                        recoveryAction = .openInstalledApplication
                        errorMessage = "当前运行的是项目调试副本。已经找到应用程序中的 Rune \(installed.version)，请打开正式版继续更新。"
                    } else {
                        recoveryAction = .openReleasePage
                        errorMessage = "当前运行的是项目调试副本，而且应用程序文件夹中没有 Rune。请下载正式版并拖入应用程序文件夹。"
                    }
                } else {
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "更新失败，请稍后再试。"
                }
            }
        }
    }

    private func openInstalledApplication() {
        errorMessage = nil
        phase = .switchingToInstalledApplication

        Task {
            do {
                try await UpdateService.openInstalledApplicationAndQuit()
            } catch {
                phase = .failed
                recoveryAction = nil
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "无法打开应用程序中的 Rune，请稍后再试。"
            }
        }
    }
}
