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
        // 单一主入口使用 ⌘⇧E，避开飞书等常驻应用普遍占用的 ⌘⇧A。
        // 若用户曾主动自定义过快捷键，loadShortcut 会继续尊重其保存值。
        static let defaultMain        = Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | shiftKey), enabled: true)
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
        case main = 8
    }

    // MARK: - Registration (Carbon RegisterEventHotKey)

    func registerAll() {
        unregisterAll()
        installHandlerIfNeeded()

        // 每次重注册前清空派发表
        Self.actionLock.withLock { Self._actionsByID.removeAll() }

        // 单一入口：截图类只注册主键 ⇧⌘A；region/fullscreen/window/ocr
        // 已并入主入口流程（旧键不再注册，避免一堆全局键互相打架）
        let activeActions: Set<Action> = [.main, .burst, .colorPicker, .recording]
        for action in Action.allCases where activeActions.contains(action) {
            let shortcut = loadShortcut(for: action) ?? defaultShortcut(for: action)
            guard shortcut.enabled else { continue }

            var ref: EventHotKeyRef?
            // signature：4 字节 OSType，用 'RUNE'（Rune）做内部标识
            let hotKeyID = EventHotKeyID(signature: OSType(0x52554E45), id: action.rawValue)
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
                print("Rune：注册热键失败 action=\(action) status=\(status)（可能键位被系统占用）")
            }
        }
        print("Rune：全局热键已注册 \(hotKeyRefs.count)/\(Action.allCases.count) 个")
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
        case .main:        return .defaultMain
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
                // 与连拍保持一致：空闲时开始，再按一次同一快捷键就结束并保存。
                if ScreenRecordingManager.shared.isRecording {
                    RecordingStatusBarController.shared.finishRecording()
                } else {
                    do {
                        let started = try await ScreenRecordingManager.shared.startRecording(on: mouseScreen)
                        if started {
                            RecordingStatusBarController.shared.show(on: mouseScreen)
                        }
                    } catch {
                        ToastWindow.shared.show(
                            title: "录屏没有开始",
                            message: error.localizedDescription,
                            systemIcon: "exclamationmark.triangle",
                            on: mouseScreen
                        )
                    }
                }
            } else if action == .burst {
                // 连拍是一级功能：空闲时直接框选并进入准备面板；拍摄中再次按下就停止。
                if BurstCaptureController.shared.isActive {
                    BurstCaptureController.shared.stop()
                } else {
                    await BurstCaptureController.shared.prepareAndBegin(presetMode: .burst, on: mouseScreen)
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

    // MARK: - 显示文本

    /// 当前生效快捷键的显示文本（如 "⇧⌘A"），界面提示一律从这里取，
    /// 用户改键后提示自动跟着变。
    func displayString(for action: Action) -> String {
        let shortcut = loadShortcut(for: action) ?? defaultShortcut(for: action)
        return shortcut.enabled ? Self.displayString(for: shortcut) : "已停用"
    }

    static func displayString(for shortcut: Shortcut) -> String {
        var text = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel(for: shortcut.keyCode)
    }

    /// Carbon 虚拟键码 → 键帽文字。
    static func keyLabel(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "空格"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "键 \(keyCode)"
        }
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
