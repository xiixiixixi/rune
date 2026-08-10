import AppKit
import CaptureKit
import CaptureKitSCK
import SwiftUI

/// Coordinates the full capture pipeline: hide window -> capture -> sound -> preview/editor.
@MainActor
@Observable
final class CaptureOrchestrator {
    static let shared = CaptureOrchestrator()

    private(set) var lastCaptureURL: URL?
    private var captureInProgress = false
    private var pendingCaptures: [(ShortcutService.Action, NSScreen?)] = []
    private var captureScreen: NSScreen?

    /// M1 第⑤步：基于 ScreenCaptureKit 的单帧截图引擎。
    /// 当前仅全屏截图走此引擎；区域/窗口/OCR/取色仍走旧的 `ScreenCapture`（系统命令）。
    private let sckEngine = SCKStillCaptureBackend()

    private init() {}

    func performCapture(_ action: ShortcutService.Action, on screen: NSScreen? = nil) async {
        if captureInProgress {
            pendingCaptures.append((action, screen))
            return
        }
        captureInProgress = true
        captureScreen = screen
        await executeCapture(action)
        while let (next, nextScreen) = pendingCaptures.first {
            pendingCaptures.removeFirst()
            captureScreen = nextScreen
            await executeCapture(next)
        }
        captureScreen = nil
        captureInProgress = false
    }

    private func executeCapture(_ action: ShortcutService.Action) async {
        switch action {
        case .region:
            // M1 第⑤步（续）：区域截图改走应用自己的 overlay + SCK 引擎。
            await captureRegionViaSCK()
        case .fullscreen:
            // M1 第⑤步：全屏截图改走 ScreenCaptureKit（单帧 API），不再用系统命令。
            await captureFullscreenViaSCK()
        case .window:
            // M1 第⑤步（续）：窗口截图改走应用自己的 WindowPickerOverlay + SCK 引擎。
            await captureWindowViaSCK()
        case .ocr:
            await performOCR()
        case .colorPicker:
            await performColorPick()
        case .recording:
            break
        }
    }

    // MARK: - Private

    /// M1 TCC 引导：截图前检查屏幕录制权限，未授权时弹引导框并打开系统设置。
    /// 返回 false 表示无权限（调用方应中止截图）。
    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // 无权限：弹引导框
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "BetterShot 需要屏幕录制权限才能截图。请在系统设置的「隐私与安全性 > 屏幕录制」中允许 BetterShot，然后重启应用。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "以后再说")
        if alert.runModal() == .alertFirstButtonReturn {
            // Deep link 到系统设置的屏幕录制页
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }

    /// M1 第⑤步：全屏截图经 ScreenCaptureKit 单帧引擎，直接拿到内存中的 CGImage，
    /// 省掉旧流程"写临时文件再读回"的重复 IO。后处理（美化/保存/预览）与旧流程一致。
    private func captureFullscreenViaSCK() async {
        guard ensureScreenCapturePermission() else { return }
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        let frame: CapturedFrame
        do {
            frame = try await sckEngine.capture(.fullscreen)
        } catch {
            print("SCK fullscreen capture failed: \(error.localizedDescription)")
            return
        }

        ScreenCapture.shared.playShutterSound()
        await processCapturedFrame(frame)
    }

    /// M1 第⑤步（续）：区域截图经应用自己的 RegionSelectionOverlay 拿选区，
    /// 再走 SCK 引擎截取该区域。不再用 screencapture -s 系统命令。
    private func captureRegionViaSCK() async {
        guard ensureScreenCapturePermission() else { return }
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        // 1. 弹应用自己的选区 overlay，拿全局点坐标矩形
        let selection = await RegionSelectionOverlay().selectRegion()
        guard let selection else { return }  // 用户取消（Esc 等）

        // 2. 走 SCK 引擎截取该区域
        let frame: CapturedFrame
        do {
            frame = try await sckEngine.capture(.region(selection.pointsRect))
        } catch {
            print("SCK region capture failed: \(error.localizedDescription)")
            return
        }

        ScreenCapture.shared.playShutterSound()
        await processCapturedFrame(frame)
    }

    /// M1 第⑤步（续）：窗口截图经应用自己的 WindowPickerOverlay 拿窗口 ID，
    /// 再走 SCK 引擎截取该窗口。不再用 screencapture -w 系统命令。
    private func captureWindowViaSCK() async {
        guard ensureScreenCapturePermission() else { return }
        // 1. 弹窗口选择器，拿 CGWindowID
        let selection = await WindowPickerOverlay().pickWindow()
        guard let selection else { return }  // 用户取消

        // 2. 走 SCK 引擎截取该窗口
        let frame: CapturedFrame
        do {
            frame = try await sckEngine.capture(.window(selection.windowID))
        } catch {
            print("SCK window capture failed: \(error.localizedDescription)")
            return
        }

        ScreenCapture.shared.playShutterSound()
        await processCapturedFrame(frame)
    }
    /// 处理一张截图（全屏/区域/窗口通用）：写入历史、美化、保存、预览。
    ///
    /// M1 §3.2 数据流对接（轻量版）：接收完整 CapturedFrame（保留 scaleFactor/displayID/capturedAt），
    /// 而非立即拆 .image。当前因 Editor/PreviewOverlay/HistoryStore 全链路仍是 URL 驱动，
    /// 这里仍需落盘喂给 HistoryStore；scaleFactor 已保留供未来多倍率导出使用。
    /// 全量内存传递（去掉落盘）留待 M2 模块化重组时，连同 Editor 入口重构一起做。
    private func processCapturedFrame(_ frame: CapturedFrame) async {
        guard let tempURL = writeCGImageToTemp(frame.image) else { return }

        let record = HistoryStore.shared.importCapture(from: tempURL)
        if let record {
            lastCaptureURL = HistoryStore.shared.urlForRecord(record)
        }
        guard let capturedURL = lastCaptureURL else { return }

        // 清理临时文件（importCapture 已复制到保存目录）
        try? FileManager.default.removeItem(at: tempURL)

        await galleryApplyAndSave(capturedURL, recordID: record?.id)
    }

    /// 把 CGImage 写到临时目录，返回 URL。供 processFullscreenFrame 喂给 HistoryStore。
    private func writeCGImageToTemp(_ cgImage: CGImage) -> URL? {
        let dir = NSTemporaryDirectory()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(fileURLWithPath: "\(dir)bettershot_sck_\(stamp).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private func captureAndProcess(_ capture: () async throws -> URL?) async {
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        do {
            guard let url = try await capture() else { return }

            ScreenCapture.shared.playShutterSound()

            let record = HistoryStore.shared.importCapture(from: url)
            if let record {
                lastCaptureURL = HistoryStore.shared.urlForRecord(record)
            }

            guard let capturedURL = lastCaptureURL else { return }

            await galleryApplyAndSave(capturedURL, recordID: record?.id)
        } catch {
            print("Capture failed: \(error.localizedDescription)")
        }
    }


    private func performColorPick() async {
        let overlay = ColorPickerOverlay()
        guard let hex = await overlay.pickColor() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        ScreenCapture.shared.playShutterSound()
        ToastWindow.shared.show(
            title: "Copied",
            message: "\(hex) copied to clipboard",
            systemIcon: "eyedropper",
            on: captureScreen
        )
    }

    /// M3：OCR 取词。走应用自己的 RegionSelectionOverlay 选区 → SCK 截图 → OCRService 识别。
    /// 不再用老的 screencapture 命令 + ScreenCapture.captureAndOCR。
    private func performOCR() async {
        guard ensureScreenCapturePermission() else { return }

        // 1. 选区（复用区域截图的选区 overlay）
        let selection = await RegionSelectionOverlay().selectRegion()
        guard let selection else { return }  // 用户取消

        // 2. SCK 截取该区域为 CGImage
        let frame: CapturedFrame
        do {
            frame = try await sckEngine.capture(.region(selection.pointsRect))
        } catch {
            print("OCR 截图失败: \(error.localizedDescription)")
            return
        }

        // 3. OCR 识别（中英文 + 条码）
        do {
            let result = try await OCRService.shared.recognize(in: frame.image)
            guard !result.isEmpty else {
                ScreenCapture.shared.playShutterSound()
                ToastWindow.shared.show(
                    title: "OCR",
                    message: "未识别到文字",
                    systemIcon: "doc.text.viewfinder",
                    on: captureScreen
                )
                return
            }
            // 复制原文到剪贴板
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.combinedText, forType: .string)
            ScreenCapture.shared.playShutterSound()

            // 翻译（参考 macshot：OCR 后附带翻译，失败则只复制原文）
            // 隐私：翻译会联网发送文字（非原图），用户主动触发 OCR 即视为同意。
            let translationMessage: String
            do {
                let translated = try await TranslationService.translate(result.combinedText)
                // 译文追加到剪贴板（原文 + 空行 + 译文）
                let combined = result.combinedText + "\n\n--- 译文 ---\n" + translated
                pasteboard.clearContents()
                pasteboard.setString(combined, forType: .string)
                translationMessage = "原文 + 译文已复制（译为 \(TranslationService.availableLanguages.first { $0.code == TranslationService.targetLanguage }?.name ?? TranslationService.targetLanguage)）"
            } catch {
                translationMessage = "原文已复制（翻译失败：\(error.localizedDescription)）"
            }

            ToastWindow.shared.show(
                title: "OCR",
                message: translationMessage,
                systemIcon: "doc.text.viewfinder",
                on: captureScreen
            )
        } catch {
            print("OCR 识别失败: \(error.localizedDescription)")
        }
    }

    private func galleryApplyAndSave(_ url: URL, recordID: UUID? = nil) async {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }

        let config = AppPreferences.defaultBeautifierConfig
        let rendered = BeautifierRenderer.render(image: cgImage, config: config)

        guard let rendered else { return }

        let savedURL = saveImage(rendered)

        if let savedURL {
            saveBaseImage(rawURL: url, alongside: savedURL)

            if let recordID {
                HistoryStore.shared.setBeautifiedPath(savedURL.path, for: recordID)
            }
        }

        if AppPreferences.copyAfterSave, let savedURL {
            copyToClipboard(savedURL)
        }

        let displayURL = savedURL ?? url

        if savedURL != nil {
            let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
            ToastWindow.shared.show(
                message: AppPreferences.copyAfterSave ? "Screenshot saved & copied!" : "Screenshot saved!",
                icon: appIcon,
                on: captureScreen
            )
        }

        PreviewOverlay.shared.show(url: displayURL, on: captureScreen)
    }

    private func saveImage(_ cgImage: CGImage) -> URL? {
        let dir = AppPreferences.saveDirectory
        let ext = AppPreferences.exportFormat.fileExtension
        // M2 自动命名保存：用 AppPreferences 生成器（系统截图风格），冲突加 _2/_3 后缀。
        let baseName = AppPreferences.generateFileName(ext: ext)
        let dirURL = URL(fileURLWithPath: dir)
        var filename = baseName
        var url = dirURL.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            let stem = (baseName as NSString).deletingPathExtension
            filename = "\(stem)_2.\(ext)"
            url = dirURL.appendingPathComponent(filename)
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            AppPreferences.exportFormat.utType as CFString,
            1, nil
        ) else { return nil }

        var options: [CFString: Any] = [:]
        if AppPreferences.exportFormat == .jpeg {
            options[kCGImageDestinationLossyCompressionQuality] = AppPreferences.exportQuality
        }

        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private func saveBaseImage(rawURL: URL, alongside beautifiedURL: URL) {
        let baseURL = Self.baseImageURL(for: beautifiedURL)
        try? FileManager.default.copyItem(at: rawURL, to: baseURL)
    }

    private static var baseStorageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BetterShot/bases", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func baseImageURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return baseStorageDir.appendingPathComponent("\(name).base.png")
    }

    static func resolveRawSource(for url: URL) -> URL {
        let baseURL = baseImageURL(for: url)
        if FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        // Legacy: check alongside the file for old .base.png files
        let legacyDir = url.deletingLastPathComponent()
        let legacyName = url.deletingPathExtension().lastPathComponent
        let legacyURL = legacyDir.appendingPathComponent("\(legacyName).base.png")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return url
    }

    private func copyToClipboard(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }
}
