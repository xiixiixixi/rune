import Carbon
import AppKit

/// 全局快捷键服务（M1 §5：改用 Carbon `RegisterEventHotKey`，不再需要辅助功能权限）。
///
/// 历史实现用 CGEvent tap 拦截全局按键，要求辅助功能权限；现改为 Carbon 热键 API，
/// 该 API 由系统直接派发热键事件，无需辅助功能权限，也不拦截/吞掉系统按键。
///
/// UI 层（PreferencesView 的快捷键录制器）产出的 (keyCode, modifiers) 本就是 Carbon
/// 格式（虚拟键码 + cmdKey|shiftKey|... 位掩码），可直接喂给 RegisterEventHotKey，
/// 故 saveShortcut/loadShortcut/registerAll/unregisterAll 签名保持不变，设置页零改动。
@MainActor
final class ShortcutService {
    static let shared = ShortcutService()

    /// 注册的 Carbon 热键引用（unregister 时用）。key = Action.rawValue。
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// 是否已安装 Carbon 事件处理器（只装一次）。
    private var handlerInstalled = false
    /// 缓存的 action 派发表（Carbon 回调通过 hot key id 查这里）。
    /// 用 NSLock 保护：Carbon 回调从主 run loop 派发（MainActor 安全），但稳妥起见加锁。
    private static let actionLock = NSLock()
    private static var _actionsByID: [UInt32: Action] = [:]

    var isRegistered: Bool { !hotKeyRefs.isEmpty }

    private init() {}

    // MARK: - Shortcut Definition

    struct Shortcut: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32
        var enabled: Bool

        // M1 §5 默认键位：区域 ⌘⇧E、全屏 ⌘⇧S、窗口 ⌘⇧W（不再覆盖系统截图快捷键 ⌘⇧3/4/5）
        static let defaultRegion      = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        static let defaultFullscreen  = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        static let defaultWindow      = Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        static let defaultOCR         = Shortcut(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        static let defaultColorPicker = Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        static let defaultRecording   = Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
        static let defaultBurst       = Shortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
    }

    enum Action: UInt32, CaseIterable {
        case region = 1
        case fullscreen = 2
        case window = 3
        case ocr = 4
        case colorPicker = 5
        case recording = 6
        case burst = 7
    }

    // MARK: - Registration (Carbon RegisterEventHotKey)

    func registerAll() {
        unregisterAll()
        installHandlerIfNeeded()

        // 每次重注册前清空派发表
        Self.actionLock.withLock { Self._actionsByID.removeAll() }

        for action in Action.allCases {
            let shortcut = loadShortcut(for: action) ?? defaultShortcut(for: action)
            guard shortcut.enabled else { continue }

            var ref: EventHotKeyRef?
            // signature：4 字节 OSType，用 'QJIE'（轻截）做内部标识
            let hotKeyID = EventHotKeyID(signature: OSType(0x514A4945), id: action.rawValue)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetEventDispatcherTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs[action.rawValue] = ref
                Self.actionLock.withLock { Self._actionsByID[action.rawValue] = action }
            } else {
                print("轻截：注册热键失败 action=\(action) status=\(status)（可能键位被系统占用）")
            }
        }
        print("轻截：全局热键已注册 \(hotKeyRefs.count)/\(Action.allCases.count) 个")
    }

    func unregisterAll() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        Self.actionLock.withLock { Self._actionsByID.removeAll() }
    }

    /// 默认快捷键（按 action 分派）。无默认值的 action（理论上都有）返回 region 默认。
    private func defaultShortcut(for action: Action) -> Shortcut {
        switch action {
        case .region:      return .defaultRegion
        case .fullscreen:  return .defaultFullscreen
        case .window:      return .defaultWindow
        case .ocr:         return .defaultOCR
        case .colorPicker: return .defaultColorPicker
        case .recording:   return .defaultRecording
        case .burst:       return .defaultBurst
        }
    }

    /// 只装一次 Carbon 事件处理器（kEventClassKeyboard/kEventHotKeyPressed）。
    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // C 函数指针不能捕获 self；用全局桥接回调，内部查 _actionsByID 派发。
        // 注意闭包内不能用 Self（会被当动态 Self 捕获），必须写具体类型名 ShortcutService。
        let handler: EventHandlerUPP = { (_, eventRef, _) -> OSStatus in
            ShortcutService.handleHotKeyEvent(eventRef!)
        }
        InstallEventHandler(
            GetEventDispatcherTarget(),
            handler,
            1,
            &spec,
            nil,
            nil
        )
        handlerInstalled = true
    }

    /// Carbon 热键事件回调（静态，从 eventRef 取 hot key id → 查派发表 → 执行 action）。
    private static func handleHotKeyEvent(_ eventRef: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let size = MemoryLayout<EventHotKeyID>.size
        let status = GetEventParameter(
            eventRef,
            UInt32(kEventParamDirectObject),
            UInt32(typeEventHotKeyID),
            nil,
            size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return status }

        let action: Action? = actionLock.withLock { _actionsByID[hotKeyID.id] }
        guard let action else { return noErr }

        let mouseScreen = NSScreen.screenAtMouse()
        Task { @MainActor in
            if action == .recording {
                if ScreenRecordingManager.shared.isRecording { return }
                let started = try? await ScreenRecordingManager.shared.startRecording(on: mouseScreen)
                if started == true {
                    RecordingStatusBarController.shared.show(on: mouseScreen)
                }
            } else if action == .burst {
                // 金手指：再按一次停止，否则开始连拍
                if BurstCaptureController.shared.isActive {
                    BurstCaptureController.shared.stop()
                    BurstStatusBarController.shared.dismiss()
                } else {
                    await BurstCaptureController.shared.start(mode: .burst, on: mouseScreen)
                    if BurstCaptureController.shared.isActive {
                        BurstStatusBarController.shared.show(on: mouseScreen)
                    }
                }
            } else {
                await CaptureOrchestrator.shared.performCapture(action, on: mouseScreen)
            }
        }
        return noErr
    }

    // MARK: - Persistence

    func saveShortcut(_ shortcut: Shortcut, for action: Action) {
        let key = "bs_hotkey_\(action.rawValue)"
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func loadShortcut(for action: Action) -> Shortcut? {
        let key = "bs_hotkey_\(action.rawValue)"
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}

// MARK: - 鼠标所在屏幕（辅助）

private extension NSScreen {
    /// 返回当前鼠标所在屏幕；拿不到时回退主屏。
    static func screenAtMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}
