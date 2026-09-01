import AppKit
import ScreenCaptureKit
import SwiftUI

@MainActor
final class RuneDelegate: NSObject, NSApplicationDelegate {
    #if DEBUG
    private var debugAuditWindow: NSWindow?
    #endif

    /// SCK 可见内容计数（取证用）：nonisolated 侧完成查询，只把 Int 带回主线程。
    nonisolated private static func fetchShareableCounts() async -> (displays: Int, windows: Int, apps: Int) {
        let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        return (
            content?.displays.count ?? -1,
            content?.windows.count ?? -1,
            content?.applications.count ?? -1
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ExceptionLogger.install()
        RuneFont.registerBundledFonts()
        AppPreferences.applyAppearance()
        NSApp.setActivationPolicy(.accessory)

        MenuBarPopoverController.shared.setup()

        #if DEBUG
        // 屏幕权限取证：对比 TCC 判定与 SCK 实际可见内容（签名失效时两者会分叉）
        if ProcessInfo.processInfo.arguments.contains("--audit-sck-content") {
            Task { @MainActor in
                // SCK 对象本身不跨隔离传递，在 nonisolated 侧先折成 Int 计数
                let counts = await Self.fetchShareableCounts()
                let report = "preflight=\(CGPreflightScreenCaptureAccess()) displays=\(counts.displays) windows=\(counts.windows) apps=\(counts.apps)"
                try? report.write(
                    toFile: "/tmp/rune-sck-content.txt",
                    atomically: true,
                    encoding: .utf8
                )
                NSApp.terminate(nil)
            }
            return
        }

        // Vision OCR 端到端：跑真图、写真结果，验证识别引擎本体。
        // 可用 --audit-ocr-real=/path/to/img.png 指定带文字的图片
        if let ocrArg = ProcessInfo.processInfo.arguments.first(
            where: { $0.hasPrefix("--audit-ocr-real") }
        ) {
            let imageURL = ocrArg.hasPrefix("--audit-ocr-real=")
                ? URL(fileURLWithPath: String(ocrArg.dropFirst("--audit-ocr-real=".count)))
                : Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                )
            Task {
                @MainActor func report(_ text: String) {
                    try? text.write(
                        toFile: "/tmp/rune-ocr-real.txt",
                        atomically: true,
                        encoding: .utf8
                    )
                    NSApp.terminate(nil)
                }
                guard let imageURL, let image = NSImage(contentsOf: imageURL),
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    report("FAIL: 找不到测试图")
                    return
                }
                do {
                    let analysis = try await OCRService.shared.analyzeCapture(in: cg)
                    let text = analysis.text ?? ""
                    let sample = text.prefix(80)
                    report(
                        "PASS: 文字块 \(analysis.textBlockCount)｜链接 \(analysis.links.count)｜"
                        + "条码 \(analysis.barcodes.count)｜敏感信息 \(analysis.sensitiveMatches.count)｜"
                        + "\(sample)…"
                    )
                } catch {
                    report("FAIL: \(error.localizedDescription)")
                }
            }
            return
        }
#endif

        #if DEBUG
        // 选区链路 E2E：跳过 Carbon 热键（键盘注入在这台机器上触发不了热键），
        // 直接走 performCapture(.main)，其余与热键路径完全一致。用于验证
        // 未激活状态下第一下点击是否送达（acceptsFirstMouse 修复）。
        if ProcessInfo.processInfo.arguments.contains("--audit-select") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Task { @MainActor in
                    await CaptureOrchestrator.shared.performCapture(.main, on: NSScreen.main)
                }
            }
            return
        }
        #endif

        // M1 §5：改用 Carbon RegisterEventHotKey，不再需要辅助功能权限，直接注册。
        ShortcutService.shared.registerAll()

        // 后台预热截图引擎（屏幕清单缓存 + 采集管线），首次截图免卡顿
        CaptureOrchestrator.shared.prewarm()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--audit-ocr-style") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OCRResultPanelController.shared.show(
                    result: OCRResult(text: "识别结果视觉自检：Rune 0.5.6\nMana 风格白卡片 + 细边框 + 橙红点缀。", barcodes: [])
                )
                DebugAuditSnapshot.captureAfter("ocr-style.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-burst-style") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                BurstSetupPanelController.shared.show(regionSizeText: "1280×720", presetMode: .fixedCount) { _ in }
                DebugAuditSnapshot.captureAfter("burst-style.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-menu-style") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MenuBarPopoverController.shared.openPopover()
                DebugAuditSnapshot.captureAfter("menu-style.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-font") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                RuneFont.runFontSelfTest()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-update-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let update = RuneUpdate(
                    version: "0.8.0",
                    notes: "新增可搜索的素材库\n改进截图与录屏的整理和复用体验\n修复若干稳定性问题",
                    releasePageURL: URL(string: "https://github.com/xiixiixixi/rune/releases/latest")!,
                    downloadURL: URL(string: "https://github.com/xiixiixixi/rune/releases/latest/download/Rune-latest.zip")
                )
                UpdateWindowController.shared.present(
                    update,
                    currentVersion: "0.7.5",
                    on: NSScreen.main
                )
                DebugAuditSnapshot.captureAfter("update-window-redesign.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-update-e2e") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                UpdateService.runEndToEndUpdate()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-update-flow") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                UpdateService.runUpdateFlowSelfTest()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-pin-drag") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                PinnedScreenshotController.shared.runPinDragSelfTest()
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-permission-state") {
            let state = CGPreflightScreenCaptureAccess() ? "granted" : "denied"
            try? state.write(
                to: URL(fileURLWithPath: "/tmp/rune-screen-permission-state.txt"),
                atomically: true,
                encoding: .utf8
            )
            NSApp.terminate(nil)
        } else if ProcessInfo.processInfo.arguments.contains("--audit-ax-state") {
            let state = UIElementDetector.isTrusted ? "granted" : "denied"
            try? state.write(
                to: URL(fileURLWithPath: "/tmp/rune-accessibility-state.txt"),
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
                DebugAuditSnapshot.captureWindowLayoutAfter("screenshot-real-layout.txt", delay: 3)
                DebugAuditSnapshot.captureAfter("screenshot-real.png", delay: 3)
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
                    forResource: "mac-asset-7",
                    withExtension: "png",
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
        } else if let settingsArgument = ProcessInfo.processInfo.arguments.first(
            where: { $0.hasPrefix("--audit-settings=") }
        ) {
            let value = String(settingsArgument.dropFirst("--audit-settings=".count))
            let section: SettingsSection? = switch value {
            case "general": .general
            case "capture": .capture
            case "recording": .recording
            case "about": .about
            default: nil
            }
            if value == "history" || value == "videos" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    CaptureLibraryWindowController.shared.open(on: NSScreen.main)
                    DebugAuditSnapshot.captureAfter("library-\(value).png", delay: 1.2)
                }
            } else if let section {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    SettingsWindowController.shared.open(on: NSScreen.main, section: section)
                    DebugAuditSnapshot.captureAfter("settings-\(value).png", delay: 1.2)
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-settings-history") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                CaptureLibraryWindowController.shared.open(on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("21-library-redesign.png")
            }
        } else if let librarySearchArgument = ProcessInfo.processInfo.arguments.first(
            where: { $0.hasPrefix("--audit-library-search=") }
        ) {
            let query = String(
                librarySearchArgument.dropFirst("--audit-library-search=".count)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                CaptureLibraryWindowController.shared.open(
                    on: NSScreen.main,
                    searchQuery: query
                )
                DebugAuditSnapshot.captureAfter("library-search.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-library") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                CaptureLibraryWindowController.shared.open(on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("library-redesign.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SettingsWindowController.shared.open(on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("settings-redesign-final.png", delay: 1.2)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-confirm-toolbar") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let hosting = NSHostingView(
                    rootView: ConfirmToolbarView(controller: .shared).runeTypography()
                )
                hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 80)
                let fitting = hosting.fittingSize
                let panel = NSPanel(
                    contentRect: NSRect(
                        origin: .zero,
                        size: NSSize(width: ceil(fitting.width), height: ceil(fitting.height))
                    ),
                    styleMask: [.borderless, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.contentView = hosting
                panel.isReleasedWhenClosed = false
                panel.center()
                panel.makeKeyAndOrderFront(nil)
                self.debugAuditWindow = panel
                DebugAuditSnapshot.captureAfter("confirm-toolbar.png", delay: 0.9)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-confirm")
                    || ProcessInfo.processInfo.arguments.contains("--audit-confirm-text")
                    || ProcessInfo.processInfo.arguments.contains("--audit-confirm-first-redaction") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let contentImageArgument = ProcessInfo.processInfo.arguments.first {
                    $0.hasPrefix("--audit-confirm-image=")
                }
                let url = contentImageArgument.map {
                    URL(fileURLWithPath: String($0.dropFirst("--audit-confirm-image=".count)))
                } ?? Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                )
                guard let url, let image = NSImage(contentsOf: url) else { return }
                var rect = NSRect(origin: .zero, size: image.size)
                guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return }
                let targetIsSecondary = ProcessInfo.processInfo.arguments.contains("--audit-secondary")
                guard let screen = targetIsSecondary
                    ? NSScreen.screens.dropFirst().first
                    : NSScreen.main else { return }
                let testsBottomEdge = ProcessInfo.processInfo.arguments.contains("--audit-bottom-edge")
                let localRegion = testsBottomEdge
                    ? CGRect(
                        x: screen.frame.width * 0.25,
                        y: screen.visibleFrame.minY - screen.frame.minY + 12,
                        width: screen.frame.width * 0.50,
                        height: screen.frame.height * 0.30
                    )
                    : CGRect(
                        x: screen.frame.width * 0.18,
                        y: screen.frame.height * 0.21,
                        width: screen.frame.width * 0.64,
                        height: screen.frame.height * 0.58
                    )
                let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
                let globalRegion = CGRect(
                    x: screen.frame.minX + localRegion.minX,
                    y: primaryHeight - (screen.frame.minY + localRegion.maxY),
                    width: localRegion.width,
                    height: localRegion.height
                )
                let crop = CGRect(
                    x: CGFloat(cgImage.width) * 0.18,
                    y: CGFloat(cgImage.height) * 0.21,
                    width: CGFloat(cgImage.width) * 0.64,
                    height: CGFloat(cgImage.height) * 0.58
                ).integral
                let capturedImage: CGImage
                if contentImageArgument != nil {
                    capturedImage = cgImage
                } else {
                    guard let cropped = cgImage.cropping(to: crop) else { return }
                    capturedImage = cropped
                }
                Task {
                    _ = await CaptureConfirmController.shared.present(
                        image: capturedImage,
                        on: screen,
                        region: globalRegion,
                        backgroundImage: cgImage
                    )
                    if ProcessInfo.processInfo.arguments.contains("--audit-confirm-transition") {
                        let transition: String
                        if CaptureConfirmController.shared.pendingScrollRequested {
                            transition = "scroll"
                        } else if CaptureConfirmController.shared.pendingBurstRequested {
                            transition = "burst"
                        } else {
                            transition = "none"
                        }
                        try? transition.write(
                            to: URL(fileURLWithPath: "/tmp/rune-confirm-transition.txt"),
                            atomically: true,
                            encoding: .utf8
                        )
                        NSApp.terminate(nil)
                    }
                }
                DebugAuditSnapshot.captureAfter(
                    contentImageArgument != nil
                        ? "39-confirm-content.png"
                        : (targetIsSecondary
                        ? "36-confirm-freeze-secondary.png"
                        : "31-confirm-freeze-redesign.png"),
                    delay: contentImageArgument == nil ? 1.1 : 3.0
                )
                // 先抓小窗，避免全屏窗口的 SCK 截图占住验收队列。
                DebugAuditSnapshot.captureSmallestAfter("confirm-toolbar.png", delay: 0.7)
                DebugAuditSnapshot.captureWindowLayoutAfter(
                    testsBottomEdge
                        ? "38-confirm-layout-bottom-edge.txt"
                        : (targetIsSecondary
                            ? "37-confirm-layout-secondary.txt"
                            : "34-confirm-layout-primary.txt"),
                    delay: 1.1
                )
            }
        } else if ProcessInfo.processInfo.arguments.contains("--audit-editor") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let url = Bundle.main.url(
                    forResource: "mac-asset-7",
                    withExtension: "png",
                    subdirectory: "Backgrounds/mac"
                ) else { return }
                EditorWindowController.shared.open(url: url, on: NSScreen.main)
                DebugAuditSnapshot.captureAfter("editor-redesign-final.png", delay: 1.2)
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
                guard let screen = NSScreen.main else { return }
                let sampleImage = Bundle.main.url(
                    forResource: "mac-asset-3",
                    withExtension: "jpg",
                    subdirectory: "Backgrounds/mac"
                ).flatMap(NSImage.init(contentsOf:))
                let stitchedPreview = sampleImage.map { image in
                    let repetitions = 4
                    let preview = NSImage(
                        size: NSSize(
                            width: image.size.width,
                            height: image.size.height * CGFloat(repetitions)
                        )
                    )
                    preview.lockFocus()
                    for index in 0..<repetitions {
                        image.draw(
                            in: CGRect(
                                x: 0,
                                y: CGFloat(index) * image.size.height,
                                width: image.size.width,
                                height: image.size.height
                            )
                        )
                    }
                    preview.unlockFocus()
                    return preview
                }
                ScrollCaptureController.shared.prepareAuditState(image: stitchedPreview)

                let target = CGRect(
                    x: screen.frame.midX - min(screen.frame.width * 0.20, 390),
                    y: screen.frame.height - screen.frame.midY - min(screen.frame.height * 0.35, 330),
                    width: min(screen.frame.width * 0.40, 780),
                    height: min(screen.frame.height * 0.70, 660)
                )
                ScrollCaptureStatusBarController.shared.show(on: screen, targetRect: target)
                DebugAuditSnapshot.captureWindowsCompositeAfter(
                    "25-scroll-feishu-flow.png",
                    on: screen,
                    background: sampleImage,
                    delay: 1.1
                )
                DebugAuditSnapshot.captureClosestToSizeAfter(
                    "25-scroll-controls.png",
                    size: CGSize(width: 470, height: 54),
                    delay: 0.8
                )
                DebugAuditSnapshot.captureClosestToSizeAfter(
                    "25-scroll-preview.png",
                    size: CGSize(width: 300, height: 860),
                    delay: 0.9
                )
                DebugAuditSnapshot.captureWindowLayoutAfter("25-scroll-layout.txt", delay: 1.0)
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

        #if DEBUG
        let automaticUpdateAuditVersion = ProcessInfo.processInfo.arguments.contains(
            "--audit-auto-update-startup"
        ) ? "0.0.1" : nil
        UpdateService.scheduleAutomaticChecks(currentVersionOverride: automaticUpdateAuditVersion)
        #else
        UpdateService.scheduleAutomaticChecks()
        #endif
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
