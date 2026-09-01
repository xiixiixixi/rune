import AppKit
import CoreGraphics
import SwiftUI

enum ScreenCapturePermissionPurpose: String {
    case screenshot = "截图"
    case burst = "连拍"
    case recording = "录屏"
    case scrollCapture = "滚动长图"
    case ocr = "文字识别"

    var continuationText: String {
        "允许后会继续\(rawValue)"
    }
}

@MainActor
@Observable
private final class ScreenCapturePermissionGuideModel {
    let purpose: ScreenCapturePermissionPurpose
    var isGranted = false
    var isChecking = false
    var needsRestart = false
    var statusText = "尚未允许 Rune"
    var detailText = "只需设置一次"

    init(purpose: ScreenCapturePermissionPurpose) {
        self.purpose = purpose
    }
}

/// 截图、连拍、录屏、长图和 OCR 共用的一次性权限引导。
/// 系统原生提示负责真正授权；这个窗口负责把原因、隐私边界和恢复路径说清楚。
@MainActor
final class ScreenCapturePermissionController: NSObject, NSWindowDelegate {
    static let shared = ScreenCapturePermissionController()

    private var window: NSWindow?
    private var model: ScreenCapturePermissionGuideModel?
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var activationObserver: NSObjectProtocol?
    private var grantPollTimer: Timer?
    private var requestedSystemPromptThisLaunch = false
    private var systemRequestReportedGranted = false
    private var openedSystemSettings = false
    private var suppressGuideThisLaunch = false
    private var auditForcesDenied = false
    private let nativePromptAttemptedKey = "rune_screen_capture_native_prompt_attempted"

    private override init() {}

    func ensurePermission(
        for purpose: ScreenCapturePermissionPurpose,
        on screen: NSScreen? = nil
    ) async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            if !continuations.isEmpty {
                finish(granted: true)
            }
            return true
        }

        // 已有权限窗口时只加入同一次等待，不重建窗口、更不连续弹多个。
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            return await waitForCurrentGuide()
        }

        // 用户已经关掉过本轮引导后，本次启动不再打扰；重启后仍会重新检测。
        if suppressGuideThisLaunch { return false }

        // 系统原生授权框只在用户第一次主动截图时请求一次。这个状态跨启动保存：
        // 被拒绝后反复调用 CGRequestScreenCaptureAccess 会让 Rune 每次启动/截图都
        // 继续弹同一个系统框。后续主动截图改为展示 Rune 自己的单一引导，由用户
        // 决定何时打开系统设置。
        let hasAttemptedNativePrompt = UserDefaults.standard.bool(
            forKey: nativePromptAttemptedKey
        )
        if !requestedSystemPromptThisLaunch, !hasAttemptedNativePrompt {
            requestedSystemPromptThisLaunch = true
            UserDefaults.standard.set(true, forKey: nativePromptAttemptedKey)
            systemRequestReportedGranted = CGRequestScreenCaptureAccess()
            if systemRequestReportedGranted, CGPreflightScreenCaptureAccess() {
                return true
            }
            // 原生提示刚结束时不再紧接着叠第二个 Rune 引导窗。
            return false
        }

        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
            presentGuide(for: purpose, on: screen)
        }
    }

    private func waitForCurrentGuide() async -> Bool {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    #if DEBUG
    func showForAudit(
        purpose: ScreenCapturePermissionPurpose,
        on screen: NSScreen? = nil
    ) {
        auditForcesDenied = true
        suppressGuideThisLaunch = false
        presentGuide(for: purpose, on: screen)
    }
    #endif

    private func presentGuide(
        for purpose: ScreenCapturePermissionPurpose,
        on screen: NSScreen?
    ) {
        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        dismissWindowOnly()

        let model = ScreenCapturePermissionGuideModel(purpose: purpose)
        if systemRequestReportedGranted {
            model.needsRestart = true
            model.statusText = "权限尚未在当前进程生效"
            model.detailText = "重新启动 Rune 后即可继续"
        }
        self.model = model

        let rootView = ScreenCapturePermissionGuideView(
            model: model,
            onOpenSettings: { [weak self] in self?.openSystemSettings() },
            onRecheck: { [weak self] in self?.recheckPermission() },
            onRestart: { [weak self] in self?.restartApplication() },
            onLater: { [weak self] in self?.finish(granted: false) }
        )
        let hostingView = NSHostingView(rootView: rootView.runeTypography())
        let size = NSSize(width: 500, height: 370)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Rune 屏幕权限"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = RuneTheme.nsBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hostingView
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]

        if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            ))
        } else {
            window.center()
        }

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        installActivationObserver()
        installGrantPolling()
    }

    /// 授权后自动感知：不再只依赖"点回 Rune 窗口"触发激活复查——
    /// 用户在系统设置里打开开关后，即使一直停在系统设置，这里也能在
    /// 数秒内发现并进入"重启后生效"引导，不会永远停在"等待"。
    private func installGrantPolling() {
        if let grantPollTimer, grantPollTimer.isValid { return }
        grantPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else {
                    self?.stopGrantPolling()
                    return
                }
                if CGPreflightScreenCaptureAccess() {
                    self.recheckPermission(autoTriggered: true)
                    self.stopGrantPolling()
                }
            }
        }
    }

    private func stopGrantPolling() {
        grantPollTimer?.invalidate()
        grantPollTimer = nil
    }

    private func openSystemSettings() {
        openedSystemSettings = true
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ), NSWorkspace.shared.open(url) else {
            model?.statusText = "没有打开系统设置"
            model?.detailText = "请手动打开“隐私与安全性”"
            return
        }
        model?.statusText = "等待你在系统设置中打开 Rune"
        model?.detailText = "返回 Rune 后会自动检查"
    }

    private func installActivationObserver() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard self?.window?.isVisible == true else { return }
                self?.recheckPermission(autoTriggered: true)
            }
        }
    }

    private func recheckPermission(autoTriggered: Bool = false) {
        guard let model, !model.isChecking else { return }
        model.isChecking = true
        model.statusText = "正在检查…"
        model.detailText = ""

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(autoTriggered ? 180 : 320))
            guard let self, let model = self.model else { return }
            let granted = !self.auditForcesDenied && CGPreflightScreenCaptureAccess()
            model.isChecking = false
            model.isGranted = granted
            if granted {
                model.statusText = "已经允许 Rune"
                model.detailText = "正在继续\(model.purpose.rawValue)…"
                try? await Task.sleep(for: .milliseconds(350))
                self.finish(granted: true)
            } else {
                model.needsRestart = self.openedSystemSettings
                    || self.systemRequestReportedGranted
                if model.needsRestart {
                    model.statusText = "权限尚未在当前进程生效"
                    model.detailText = "重新启动 Rune 后即可继续"
                } else {
                    model.statusText = "还没有允许 Rune"
                    model.detailText = "请在系统设置中打开 Rune"
                }
            }
        }
    }

    private func restartApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]

        do {
            try process.run()
            finish(granted: false)
            NSApp.terminate(nil)
        } catch {
            model?.statusText = "没有成功重新启动"
            model?.detailText = "请手动退出并重新打开 Rune"
        }
    }

    private func finish(granted: Bool) {
        let continuations = self.continuations
        self.continuations.removeAll()
        if !granted {
            suppressGuideThisLaunch = true
        }
        dismissWindowOnly()
        auditForcesDenied = false
        continuations.forEach { $0.resume(returning: granted) }
    }

    private func dismissWindowOnly() {
        stopGrantPolling()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
        window?.orderOut(nil)
        window = nil
        model = nil
        openedSystemSettings = false
    }

    func windowWillClose(_ notification: Notification) {
        finish(granted: false)
    }
}

private struct ScreenCapturePermissionGuideView: View {
    @Bindable var model: ScreenCapturePermissionGuideModel
    let onOpenSettings: () -> Void
    let onRecheck: () -> Void
    let onRestart: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.top, 30)

            HStack(alignment: .top, spacing: 16) {
                steps
                VStack(alignment: .leading, spacing: 12) {
                    privacyCard
                    status
                }
            }
            .padding(.top, 22)

            Spacer(minLength: 18)

            HStack(spacing: 10) {
                Button("稍后") { onLater() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if model.needsRestart {
                    Button(action: onRestart) {
                        RuneTheme.primaryButtonLabel("重新启动 Rune")
                    }
                        .buttonStyle(RuneTheme.RunePressStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(action: onRecheck) {
                        RuneTheme.secondaryButtonLabel("重新检查")
                    }
                        .buttonStyle(RuneTheme.RunePressStyle())
                        .disabled(model.isChecking)

                    Button(action: onOpenSettings) {
                        RuneTheme.primaryButtonLabel("打开系统设置")
                    }
                        .buttonStyle(RuneTheme.RunePressStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 20)
        .frame(width: 500, height: 370)
        .background(RuneAmbientBackdrop())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "macwindow")
                .font(RuneFont.swiftUI(size: 24, weight: .medium))
                .foregroundStyle(RuneTheme.textSecondary)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 5) {
                Text("先允许 Rune 看见屏幕")
                    .font(RuneFont.swiftUI(size: 17, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                Text("这是截图、连拍和录屏共同需要的一次设置")
                    .font(RuneFont.swiftUI(size: 13))
                    .foregroundStyle(RuneTheme.textSecondary)
                Text(model.purpose.continuationText)
                    .font(RuneFont.swiftUI(size: 12, weight: .medium))
                    .foregroundStyle(RuneTheme.textPrimary)
                    .overlay(alignment: .bottomLeading) {
                        RuneSelectionUnderline(width: 34)
                            .offset(y: 4)
                    }
            }
        }
    }

    private var privacyCard: some View {
        HStack(alignment: .top, spacing: 10) {
            RuneOpticalIconPlate(systemImage: "lock.shield", size: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("只在你主动截图、连拍或录屏时读取画面")
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                Text("识别、打码和图片处理都在这台 Mac 上完成。")
                    .font(RuneFont.swiftUI(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RuneCardBackground())
        .accessibilityElement(children: .combine)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionStep(number: "1", title: "打开系统设置")
            stepConnector
            permissionStep(number: "2", title: "打开 Rune")
            stepConnector
            permissionStep(number: "3", title: "返回 Rune")
        }
        .padding(12)
        .frame(width: 152, alignment: .leading)
        .background(RuneCardBackground(cornerRadius: RuneTheme.plateCorner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("授权步骤：打开系统设置，打开 Rune，返回 Rune")
    }

    private func permissionStep(number: String, title: String) -> some View {
        HStack(spacing: 9) {
            Text(number)
                .font(RuneFont.swiftUI(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(RuneTheme.primaryOnFill)
                .frame(width: 24, height: 24)
                .background(Circle().fill(RuneTheme.primaryFill))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            Text(title)
                .font(RuneFont.swiftUI(size: 11, weight: .medium))
                .foregroundStyle(RuneTheme.textPrimary)
                .lineLimit(1)
        }
        .frame(height: 30)
    }

    private var stepConnector: some View {
        Rectangle()
            .fill(RuneTheme.separator)
            .frame(width: 1, height: 18)
            .padding(.leading, 12)
    }

    private var status: some View {
        HStack(spacing: 8) {
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: model.isGranted ? "checkmark.circle.fill" : "circle.dashed")
                    .font(RuneFont.swiftUI(size: 14, weight: .medium))
                    .foregroundStyle(model.isGranted ? Color(nsColor: .systemGreen) : RuneTheme.textMuted)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusText)
                    .font(RuneFont.swiftUI(size: 12, weight: .semibold))
                if !model.detailText.isEmpty {
                    Text(model.detailText)
                        .font(RuneFont.swiftUI(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RuneCardBackground(cornerRadius: RuneTheme.plateCorner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("权限状态：\(model.statusText)，\(model.detailText)")
    }
}
