import AppKit

@MainActor
final class RuneDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ExceptionLogger.install()
        AppPreferences.applyAppearance()
        NSApp.setActivationPolicy(.accessory)

        MenuBarPopoverController.shared.setup()

        // M1 §5：改用 Carbon RegisterEventHotKey，不再需要辅助功能权限，直接注册。
        ShortcutService.shared.registerAll()

        // 后台预热截图引擎（屏幕清单缓存 + 采集管线），首次截图免卡顿
        CaptureOrchestrator.shared.prewarm()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-permission-state") {
            let state = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
            try? state.write(
                to: URL(fileURLWithPath: "/tmp/rune-screen-permission-state.txt"),
                atomically: true,
                encoding: .utf8
            )
            NSApp.terminate(nil)
        } else if ProcessInfo.processInfo.arguments.contains("--audit-permission-redesign") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let targetScreen = ProcessInfo.processInfo.arguments.contains("--audit-secondary")
                    ? NSScreen.screens.dropFirst().first
                    : NSScreen.main
                ScreenCapturePermissionController.shared.showForAudit(
                    purpose: .burst,
                    on: targetScreen
                )
                DebugAuditSnapshot.captureAfter("30-permission-redesign.png", delay: 1.1)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-permission-current") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let alert = NSAlert()
                alert.messageText = "需要屏幕录制权限"
                alert.informativeText = "Rune 需要屏幕录制权限才能截图。请在系统设置的「隐私与安全性 > 屏幕与系统音频录制」中允许“Rune”，然后重新打开 Rune。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "以后再说")
                alert.runModal()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-burst-interactive") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                BurstSetupPanelController.shared.show(
                    regionSizeText: "1280×720",
                    presetMode: .fixedCount
                ) { mode in
                    BurstLiveBarController.shared.show(
                        mode: mode,
                        auditAllowsInteraction: true
                    ) {
                        guard let source = Bundle.main.url(
                            forResource: "mac-asset-3",
                            withExtension: "jpg",
                            subdirectory: "Backgrounds/mac"
                        ) else { return }
                        let directory = FileManager.default.temporaryDirectory
                            .appendingPathComponent("Rune 连拍交互验收", isDirectory: true)
                        try? FileManager.default.removeItem(at: directory)
                        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        for index in 1...12 {
                            let target = directory.appendingPathComponent(
                                String(format: "连拍_%03d.png", index)
                            )
                            try? FileManager.default.copyItem(at: source, to: target)
                        }
                        BurstReviewWindowController.shared.show(directory: directory)
                    }
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-burst-real") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Task {
                    await BurstCaptureController.shared.prepareAndBegin(
                        presetMode: .fixedCount,
                        on: NSScreen.main
                    )
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-screenshot-real") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Task {
                    await CaptureOrchestrator.shared.performCapture(.main, on: NSScreen.main)
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-ocr") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let result = OCRResult(
                    text: "Rune 让截图更轻、更快。\n识别后的文字可以在这里修正，再复制到剪贴板。",
                    barcodes: ["https://github.com/xiixiixixi/rune"]
                )
                OCRResultPanelController.shared.show(result: result, on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("16-ocr-result-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-recording") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                RecordingStatusBarController.shared.show(
                    on: NSScreen.main,
                    auditElapsedSeconds: 83
                )
                DebugAuditSnapshot.captureAfter("18-recording-status-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let url = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ) else { return }
                PreviewOverlay.shared.show(url: url, on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("17-preview-card-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-video-preview") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let url = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ) else { return }
                PreviewOverlay.shared.show(
                    url: url,
                    on: NSScreen.main,
                    kindOverride: .recording
                )
                DebugAuditSnapshot.captureAfter("22-video-result-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-video-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let url = URL(fileURLWithPath: "/tmp/rune-video-audit.mp4")
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                VideoEditorWindowController.shared.open(url: url, on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("28-video-editor-progressive-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-pin") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let url = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ) else { return }
                PinnedScreenshotController.shared.pin(
                    url: url,
                    on: NSScreen.main,
                    auditShowsControls: true
                )
                DebugAuditSnapshot.captureAfter("19-pin-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-settings-history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindowController.shared.open(on: NSScreen.main, section: .history)
                DebugAuditSnapshot.captureAfter("21-history-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindowController.shared.open(on: NSScreen.main)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-confirm") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let url = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ), let image = NSImage(contentsOf: url) else { return }
                var rect = NSRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
                Task {
                    _ = await CaptureConfirmController.shared.present(
                        image: cgImage,
                        on: NSScreen.main,
                        region: NSScreen.main?.frame
                    )
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let url = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ) else { return }
                EditorWindowController.shared.open(url: url, on: NSScreen.main)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-burst-setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let targetScreen = ProcessInfo.processInfo.arguments.contains("--audit-secondary")
                    ? NSScreen.screens.dropFirst().first
                    : NSScreen.main
                BurstSetupPanelController.shared.show(
                    regionSizeText: "1280×720",
                    presetMode: .burst,
                    on: targetScreen,
                    onBegin: { _ in }
                )
                DebugAuditSnapshot.captureAfter("27-burst-setup-icon-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-burst-live") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                BurstLiveBarController.shared.show(mode: .burst, onStop: {})
                DebugAuditSnapshot.captureAfter("23-burst-live-controls-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-burst-review") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let source = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ) else { return }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Rune 连拍验收", isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in 1...12 {
                    let target = directory.appendingPathComponent(
                        String(format: "连拍_%03d.png", index)
                    )
                    try? FileManager.default.copyItem(at: source, to: target)
                }
                BurstReviewWindowController.shared.show(directory: directory, preselectedCount: 3)
                DebugAuditSnapshot.captureAfter("24-burst-review-selection-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-scroll") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                ScrollCaptureStatusBarController.shared.show(on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("25-scroll-status-redesign.png")
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-toast") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                ToastWindow.shared.show(
                    title: "连拍完成",
                    message: "已拍 18 张，可以挑选、删除或导出",
                    systemIcon: "camera.fill",
                    duration: 10
                )
                DebugAuditSnapshot.captureAfter("26-toast-redesign.png")
            }
        }
        #endif

        UpdateService.scheduleAutomaticCheckIfNeeded()
    }


    func applicationWillTerminate(_ notification: Notification) {
        ShortcutService.shared.unregisterAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
