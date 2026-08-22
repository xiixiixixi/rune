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
    private var captureScreen: NSScreen?

    /// 基于 ScreenCaptureKit 的单帧截图引擎，供全屏、区域、窗口和 OCR 使用。
    private let sckEngine = SCKStillCaptureBackend()

    private init() {}

    func performCapture(_ action: ShortcutService.Action, on screen: NSScreen? = nil) async {
        // 截图和权限引导都是交互流程；重复热键直接忽略，不能排队后连续弹窗。
        guard !captureInProgress else { return }
        captureInProgress = true
        captureScreen = screen
        defer {
            captureScreen = nil
            captureInProgress = false
        }
        await executeCapture(action)
    }

    private func executeCapture(_ action: ShortcutService.Action) async {
        switch action {
        case .region, .main:
            // 区域+窗口+全屏三合一交互；main=单一主入口 ⌘⇧A（功能截完再展示）
            await captureRegionViaSCK()
        case .fullscreen:
            // 区域+窗口+全屏合并：三种截图同一交互
            // （拖拽=区域 / 点窗口=整窗 / 点桌面空白=全屏）。
            // 旧 captureFullscreenViaSCK 保留但不再触发。
            await captureRegionViaSCK()
        case .window:
            // 区域+窗口合并：窗口截图并入区域交互（悬停识别窗口单击截取，
            // 拖拽=自定义区域）。旧 WindowPickerOverlay 保留但不再触发。
            await captureRegionViaSCK()
        case .ocr:
            await performOCR()
        case .colorPicker:
            await performColorPick()
        case .recording:
            break
        case .burst:
            // 连拍在 ShortcutService 热键回调里直接处理（开始/停止），不走 orchestrator。
            break
        }
    }

    // MARK: - Private

    /// M1 TCC 引导：截图前检查屏幕录制权限，未授权时弹引导框并打开系统设置。
    /// 返回 false 表示无权限（调用方应中止截图）。
    private func ensureScreenCapturePermission(
        for purpose: ScreenCapturePermissionPurpose
    ) async -> Bool {
        await ScreenCapturePermissionController.shared.ensurePermission(
            for: purpose,
            on: captureScreen
        )
    }

    /// M1 第⑤步：全屏截图经 ScreenCaptureKit 单帧引擎，直接拿到内存中的 CGImage，
    /// 省掉旧流程"写临时文件再读回"的重复 IO。后处理（美化/保存/预览）与旧流程一致。
    private func captureFullscreenViaSCK() async {
        guard await ensureScreenCapturePermission(for: .screenshot) else { return }
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        let frame: CapturedFrame
        do {
            if let captureScreen, let displayID = Self.displayID(for: captureScreen) {
                frame = try await sckEngine.capture(.display(displayID))
            } else {
                frame = try await sckEngine.capture(.fullscreen)
            }
        } catch {
            print("全屏截图失败：\(error.localizedDescription)")
            showCaptureError("截图失败", detail: "没有抓到屏幕画面，请重试")
            return
        }

        ScreenCapture.shared.playShutterSound()
        await processCapturedFrame(frame)
    }

    /// M1 第⑤步（续）：区域截图经应用自己的 RegionSelectionOverlay 拿选区，
    /// 再走 SCK 引擎截取该区域。不再用 screencapture -s 系统命令。
    private func captureRegionViaSCK() async {
        guard await ensureScreenCapturePermission(for: .screenshot) else { return }
        let delay = AppPreferences.selfTimerDelay
        if delay != .off {
            await CountdownOverlay.shared.showCountdown(seconds: delay.rawValue)
        }

        // 拖框期间后台预热引擎（屏幕清单+采集管线），松手即拍
        prewarmEngineInBackground()

        // 1. 弹应用自己的选区 overlay，拿全局点坐标矩形
        let selection = await RegionSelectionOverlay().selectRegion()
        guard let selection else { return }  // 用户取消（Esc 等）

        // 2. 走 SCK 引擎：单击命中窗口=整窗捕获（无阴影）；拖拽=区域裁剪
        let frame: CapturedFrame
        do {
            if let windowID = selection.windowID {
                frame = try await sckEngine.capture(.window(windowID))
            } else {
                frame = try await sckEngine.capture(.region(selection.pointsRect))
            }
        } catch {
            print("区域截图失败：\(error.localizedDescription)")
            showCaptureError("截图失败", detail: "选区没有保存，请重新截一次")
            return
        }

        ScreenCapture.shared.playShutterSound()
        // 冻结屏+底部工具栏跟随实际框选所在屏（而非按热键时鼠标所在屏）
        await processCapturedFrame(
            frame,
            on: Self.screen(forDisplayID: selection.displayID),
            region: selection.pointsRect
        )
    }

    /// M1 第⑤步（续）：窗口截图经应用自己的 WindowPickerOverlay 拿窗口 ID，
    /// 再走 SCK 引擎截取该窗口。不再用 screencapture -w 系统命令。
    /// 后台预热截图引擎（不阻塞当前流程）。
    /// 屏幕清单查询 0.5–1.5s 是截图卡顿的元凶；在 overlay 交互期间提前做完。
    private func prewarmEngineInBackground() {
        Task.detached(priority: .userInitiated) { [sckEngine] in
            try? await sckEngine.prewarm()
        }
    }

    /// 供启动时调用：把引擎焐热，首次截图也快。
    /// 并启动常驻保温：每 25 秒后台续一次热（缓存 TTL 30s），
    /// 消灭"启动 30 秒后第一次截图回到冷启动慢 1-2.5s"的问题。
    private var keepAliveTask: Task<Void, Never>?

    func prewarm() {
        prewarmEngineInBackground()
        guard keepAliveTask == nil else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { break }
                self?.prewarmEngineInBackground()
            }
        }
    }

    private func captureWindowViaSCK() async {
        guard await ensureScreenCapturePermission(for: .screenshot) else { return }
        // 挑窗口期间后台预热引擎
        prewarmEngineInBackground()
        // 1. 弹窗口选择器，拿 CGWindowID
        let selection = await WindowPickerOverlay().pickWindow()
        guard let selection else { return }  // 用户取消

        // 2. 走 SCK 引擎截取该窗口
        let frame: CapturedFrame
        do {
            frame = try await sckEngine.capture(.window(selection.windowID))
        } catch {
            print("窗口截图失败：\(error.localizedDescription)")
            showCaptureError("窗口截图失败", detail: "这个窗口暂时无法捕获，请重试")
            return
        }

        ScreenCapture.shared.playShutterSound()
        await processCapturedFrame(frame)
    }
    /// 处理一张截图（全屏/区域/窗口通用）：**先确认后保存**（docs/交互设计.md 确认模式）。
    ///
    /// 流程：截图 → 确认模式（冻结屏+底部工具栏，可就地标注）→
    /// - 取消/Esc：直接 return，零残留（不写文件、不建历史）
    /// - 保存/Enter：带着标注走落盘链（临时文件→HistoryStore→美化烘焙标注→预览）
    private func processCapturedFrame(
        _ frame: CapturedFrame,
        on screen: NSScreen? = nil,
        region: CGRect? = nil
    ) async {
        // 确认模式：用户在冻结屏上标注，点保存才继续。
        // 「滚动长图」会以 nil 结束确认并留下 pendingScrollRegion → 转滚动截图。
        let annotations = await CaptureConfirmController.shared.present(
            image: frame.image,
            on: screen ?? captureScreen,
            region: region
        )
        if let scrollRegion = CaptureConfirmController.shared.pendingScrollRegion {
            CaptureConfirmController.shared.clearPendingScroll()
            await ScrollCaptureController.shared.start(on: screen, presetRegion: scrollRegion)
            return
        }
        if let burstRegion = CaptureConfirmController.shared.pendingBurstRegion {
            CaptureConfirmController.shared.clearPendingBurst()
            BurstCaptureController.shared.configureAndBegin(
                presetMode: .burst,
                on: screen,
                region: burstRegion
            )
            return
        }
        guard let annotations else { return }   // 取消：零残留

        guard let tempURL = writeCGImageToTemp(frame.image) else { return }

        guard let record = await HistoryStore.shared.importCapture(from: tempURL) else {
            try? FileManager.default.removeItem(at: tempURL)
            showCaptureError("截图没有保存", detail: "请检查磁盘空间后重试")
            return
        }
        let capturedURL = HistoryStore.shared.urlForRecord(record)
        lastCaptureURL = capturedURL

        // 清理临时文件（importCapture 已复制到保存目录）
        try? FileManager.default.removeItem(at: tempURL)

        await galleryApplyAndSave(capturedURL, recordID: record.id, annotations: annotations)
    }

    /// 供滚动截图等扩展功能复用统一的保存、美化、历史与预览流程。
    func processExternalFrame(_ frame: CapturedFrame) async {
        await processCapturedFrame(frame)
    }

    /// 把 CGImage 写到临时目录，返回 URL。供 processFullscreenFrame 喂给 HistoryStore。
    private func writeCGImageToTemp(_ cgImage: CGImage) -> URL? {
        let dir = NSTemporaryDirectory()
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = URL(fileURLWithPath: "\(dir)Rune_临时_\(stamp).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return url
    }

    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }

    /// 显示器编号 → NSScreen（RegionSelection 只传编号，这里换回屏幕对象）。
    private static func screen(forDisplayID id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(for: $0) == id }
    }

    private func performColorPick() async {
        let overlay = ColorPickerOverlay()
        guard let hex = await overlay.pickColor() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        ScreenCapture.shared.playShutterSound()
        ToastWindow.shared.show(
            title: "已复制",
            message: "颜色值 \(hex) 已复制到剪贴板",
            systemIcon: "eyedropper",
            on: captureScreen
        )
    }

    /// M3：OCR 取词。走应用自己的 RegionSelectionOverlay 选区 → SCK 截图 → OCRService 识别。
    /// 不再用老的 screencapture 命令 + ScreenCapture.captureAndOCR。
    private func performOCR() async {
        guard await ensureScreenCapturePermission(for: .ocr) else { return }
        // 1. 选区（复用区域截图的选区 overlay）
        let selection = await RegionSelectionOverlay().selectRegion()
        guard let selection else { return }  // 用户取消

        // 2. SCK 截取该区域为 CGImage
        let frame: CapturedFrame
        do {
            frame = try await sckEngine.capture(.region(selection.pointsRect))
        } catch {
            print("OCR 截图失败: \(error.localizedDescription)")
            showCaptureError("文字识别失败", detail: "选区没有捕获成功，请重试")
            return
        }

        // 3. OCR 识别（中英文 + 条码）
        do {
            let result = try await OCRService.shared.recognize(in: frame.image)
            guard !result.isEmpty else {
                ScreenCapture.shared.playShutterSound()
                ToastWindow.shared.show(
                    title: "文字识别",
                    message: "未识别到文字",
                    systemIcon: "doc.text.viewfinder",
                    on: captureScreen
                )
                return
            }
            ScreenCapture.shared.playShutterSound()
            OCRResultPanelController.shared.show(
                result: result,
                near: selection.pointsRect,
                on: captureScreen
            )
        } catch {
            print("OCR 识别失败: \(error.localizedDescription)")
            ToastWindow.shared.show(
                title: "文字识别失败",
                message: error.localizedDescription,
                systemIcon: "exclamationmark.triangle",
                on: captureScreen
            )
        }
    }

    private func galleryApplyAndSave(_ url: URL, recordID: UUID? = nil, annotations: [AnnotationItem] = []) async {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            showCaptureError("无法读取截图", detail: "原图仍保留在 Rune 历史中")
            return
        }

        let config = AppPreferences.defaultBeautifierConfig
        // 确认模式：标注随成品一起烘焙（底图 base 仍存无标注原图，编辑器可重编）
        let rendered = BeautifierRenderer.render(image: cgImage, config: config, annotations: annotations)

        guard let rendered else {
            showCaptureError("无法生成截图", detail: "原图仍保留在 Rune 历史中")
            return
        }

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
                message: AppPreferences.copyAfterSave ? "截图已保存并复制！" : "截图已保存！",
                icon: appIcon,
                on: captureScreen
            )
        } else {
            ToastWindow.shared.show(
                title: "无法写入所选文件夹",
                message: "原图已保存在 Rune 历史中，请检查保存位置",
                systemIcon: "exclamationmark.triangle",
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
        let stem = (baseName as NSString).deletingPathExtension
        var filename = baseName
        var url = dirURL.appendingPathComponent(filename)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            filename = "\(stem)_\(suffix).\(ext)"
            url = dirURL.appendingPathComponent(filename)
            suffix += 1
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
        let dir = appSupport.appendingPathComponent("Rune/bases", isDirectory: true)
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
        // 兼容改名前 BetterShot 目录中的原图。
        let oldSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BetterShot/bases", isDirectory: true)
            .appendingPathComponent(baseURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: oldSupport.path) {
            return oldSupport
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

    private func showCaptureError(_ title: String, detail: String) {
        ToastWindow.shared.show(
            title: title,
            message: detail,
            systemIcon: "exclamationmark.triangle",
            on: captureScreen
        )
    }
}
