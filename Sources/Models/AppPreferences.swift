import Foundation
import AppKit
import SwiftUI

enum AppPreferences {
    // MARK: - Keys
    private static let saveDirKey = "bs_saveDirectory"
    private static let copyAfterSaveKey = "bs_copyAfterSave"
    private static let playSoundKey = "bs_playSound"
    private static let overlayPositionKey = "bs_overlayPosition"
    private static let overlayDismissDelayKey = "bs_overlayDismissDelay"
    private static let exportFormatKey = "bs_exportFormat"
    private static let exportQualityKey = "bs_exportQuality"
    private static let selfTimerKey = "bs_selfTimerDelay"
    private static let recordingFPSKey = "bs_recordingFPS"
    private static let recordingShowCursorKey = "bs_recordingShowCursor"
    private static let recordingCaptureAudioKey = "bs_recordingCaptureAudio"
    private static let fileNameFormatKey = "bs_fileNameFormat"
    private static let confirmReturnActionKey = "rune_confirmReturnAction"
    private static let captureFlowKey = "rune_captureFlow"
    private static let lastAutomaticUpdateCheckKey = "rune_lastAutomaticUpdateCheck"
    private static let lastPresentedUpdateVersionKey = "rune_lastPresentedUpdateVersion"
    private static let lastUpdatePresentationDateKey = "rune_lastUpdatePresentationDate"
    private static let detectUIElementsKey = "rune_detectUIElements"

    // MARK: - Appearance

    /// 跟随 macOS 系统外观，让玻璃、系统控件和辅助功能保持一致。
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = nil
    }

    // MARK: - General
    static var saveDirectory: String {
        get {
            #if DEBUG
            let prefix = "--audit-save-directory="
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) {
                return String(argument.dropFirst(prefix.count))
            }
            #endif
            return UserDefaults.standard.string(forKey: saveDirKey) ?? NSHomeDirectory() + "/Desktop"
        }
        set { UserDefaults.standard.set(newValue, forKey: saveDirKey) }
    }

    // MARK: - File Naming（M2 自动命名保存）

    /// 截图保存的文件名格式。默认系统截图风格，让用户在 Finder 一眼认出。
    static var fileNameFormat: FileNameFormat {
        get {
            guard let raw = UserDefaults.standard.string(forKey: fileNameFormatKey),
                  let fmt = FileNameFormat(rawValue: raw) else { return .systemStyle }
            return fmt
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: fileNameFormatKey) }
    }

    /// 生成截图文件名（不含目录）。
    /// - systemStyle: `截图 2026-08-09 15.20.33.png`（冒号在文件名非法，用点分隔时分秒）
    /// - legacy: `Rune_<毫秒时间戳>.<ext>`
    static func generateFileName(date: Date = Date(), ext: String) -> String {
        let safeExt = ext.isEmpty ? "png" : ext
        switch fileNameFormat {
        case .systemStyle:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            return "截图 \(formatter.string(from: date)).\(safeExt)"
        case .legacy:
            return "Rune_\(Int(date.timeIntervalSince1970 * 1000)).\(safeExt)"
        }
    }

    static var copyAfterSave: Bool {
        get { UserDefaults.standard.object(forKey: copyAfterSaveKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: copyAfterSaveKey) }
    }

    /// 截图确认台按 Enter（或空白处双击）时的收尾动作。
    /// 出厂为「仅复制」：最常见的用法是直接粘进聊天窗口，不该顺手往桌面丢文件。
    static var confirmReturnAction: ConfirmReturnAction {
        get {
            guard let raw = UserDefaults.standard.string(forKey: confirmReturnActionKey),
                  let action = ConfirmReturnAction(rawValue: raw) else { return .copyOnly }
            return action
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: confirmReturnActionKey) }
    }

    /// 框选松手之后的走向。框选时按着 ⌥ 可临时反转（见 RegionSelection.togglesQuickCopy）。
    static var captureFlow: CaptureFlow {
        get {
            guard let raw = UserDefaults.standard.string(forKey: captureFlowKey),
                  let flow = CaptureFlow(rawValue: raw) else { return .confirm }
            return flow
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: captureFlowKey) }
    }

    static var playSound: Bool {
        get { UserDefaults.standard.object(forKey: playSoundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: playSoundKey) }
    }

    /// 类 Snipaste 的窗口内界面区域识别。默认打开逻辑但不主动索权；
    /// 没有辅助功能权限时自动退回普通窗口识别。
    static var detectUIElements: Bool {
        get {
            if UserDefaults.standard.object(forKey: detectUIElementsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: detectUIElementsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: detectUIElementsKey) }
    }

    // MARK: - Updates

    static var lastAutomaticUpdateCheck: Date {
        get {
            let timestamp = UserDefaults.standard.double(forKey: lastAutomaticUpdateCheckKey)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : .distantPast
        }
        set {
            UserDefaults.standard.set(
                newValue.timeIntervalSince1970,
                forKey: lastAutomaticUpdateCheckKey
            )
        }
    }

    static var lastPresentedUpdateVersion: String? {
        get { UserDefaults.standard.string(forKey: lastPresentedUpdateVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastPresentedUpdateVersionKey) }
    }

    static var lastUpdatePresentationDate: Date {
        get {
            let timestamp = UserDefaults.standard.double(forKey: lastUpdatePresentationDateKey)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : .distantPast
        }
        set {
            UserDefaults.standard.set(
                newValue.timeIntervalSince1970,
                forKey: lastUpdatePresentationDateKey
            )
        }
    }

    // MARK: - Overlay
    static var overlayPosition: OverlayPosition {
        get {
            guard let raw = UserDefaults.standard.string(forKey: overlayPositionKey),
                  let pos = OverlayPosition(rawValue: raw) else { return .bottomRight }
            return pos
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: overlayPositionKey) }
    }

    static var overlayDismissDelay: Double {
        get {
            let val = UserDefaults.standard.double(forKey: overlayDismissDelayKey)
            return val > 0 ? val : 5.0
        }
        set { UserDefaults.standard.set(newValue, forKey: overlayDismissDelayKey) }
    }

    // MARK: - Export
    static var exportFormat: ExportFormat {
        get {
            guard let raw = UserDefaults.standard.string(forKey: exportFormatKey),
                  let fmt = ExportFormat(rawValue: raw) else { return .png }
            return fmt
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: exportFormatKey) }
    }

    static var exportQuality: Double {
        get {
            let val = UserDefaults.standard.double(forKey: exportQualityKey)
            return val > 0 ? val : 0.9
        }
        set { UserDefaults.standard.set(newValue, forKey: exportQualityKey) }
    }

    // MARK: - Self Timer
    static var selfTimerDelay: SelfTimerDelay {
        get {
            let val = UserDefaults.standard.integer(forKey: selfTimerKey)
            return SelfTimerDelay(rawValue: val) ?? .off
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selfTimerKey) }
    }

    // MARK: - Recording
    static var recordingFPS: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: recordingFPSKey)
            return val > 0 ? val : 30
        }
        set { UserDefaults.standard.set(newValue, forKey: recordingFPSKey) }
    }

    static var recordingShowCursor: Bool {
        get { UserDefaults.standard.object(forKey: recordingShowCursorKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: recordingShowCursorKey) }
    }

    static var recordingCaptureAudio: Bool {
        get { UserDefaults.standard.object(forKey: recordingCaptureAudioKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: recordingCaptureAudioKey) }
    }

    // MARK: - Default Beautifier Config
    static var defaultBeautifierConfig: BeautifierConfig {
        get {
            guard let data = UserDefaults.standard.data(forKey: "bs_defaultBeautifierConfig"),
                  let config = try? JSONDecoder().decode(BeautifierConfig.self, from: data)
            else { return .default }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "bs_defaultBeautifierConfig")
            }
        }
    }
}

// MARK: - Enums

enum OverlayPosition: String, CaseIterable, Codable {
    case bottomRight = "bottomRight"
    case bottomLeft = "bottomLeft"
}

enum ExportFormat: String, CaseIterable {
    case png, jpeg

    var utType: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }
}

enum SelfTimerDelay: Int, CaseIterable {
    case off = 0
    case three = 3
    case five = 5
    case ten = 10

    var label: String {
        switch self {
        case .off: return "关闭"
        default: return "\(rawValue) 秒"
        }
    }
}

/// 框选松手后是打开确认台，还是直接进剪贴板。
enum CaptureFlow: String, CaseIterable {
    /// 冻结画面 + 工具台，标注/识字/长图之后再生产品（默认，Rune 的招牌流程）。
    case confirm
    /// 不打断：框完即进剪贴板与素材库，等同在确认台上点「复制」。
    case quickCopy

    var label: String {
        switch self {
        case .confirm: return "打开确认台"
        case .quickCopy: return "直接复制"
        }
    }

    var detail: String {
        switch self {
        case .confirm: return "冻结画面，可以标注、识字、转长图"
        case .quickCopy: return "框完即进剪贴板与素材库，不打断手上的事"
        }
    }

    var icon: String {
        switch self {
        case .confirm: return "slider.horizontal.3"
        case .quickCopy: return "doc.on.doc"
        }
    }
}

/// 截图确认台的回车默认动作。
enum ConfirmReturnAction: String, CaseIterable {
    /// 只进剪贴板 + Rune 历史（出厂默认）。
    case copyOnly = "copyOnly"
    /// 剪贴板 + 保存到文件夹。
    case copyAndSave = "copyAndSave"
    /// 只保存到文件夹（是否复制看「保存后复制」）。
    case save = "save"

    var label: String {
        switch self {
        case .copyOnly: return "仅复制"
        case .copyAndSave: return "复制并保存"
        case .save: return "仅保存"
        }
    }

    var icon: String {
        switch self {
        case .copyOnly: return "doc.on.doc"
        case .copyAndSave: return "square.on.square"
        case .save: return "square.and.arrow.down"
        }
    }

    var detail: String {
        switch self {
        case .copyOnly: return "进剪贴板和历史，不写保存文件夹"
        case .copyAndSave: return "剪贴板 + 保存文件夹各一份"
        case .save: return "只写保存文件夹，是否复制看上面的开关"
        }
    }
}

/// 截图文件名格式（M2 自动命名保存）。
enum FileNameFormat: String, CaseIterable {
    /// 中文截图风格：`截图 2026-08-09 15.20.33.png`
    case systemStyle = "system"
    /// 旧风格：`Rune_<毫秒时间戳>.png`
    case legacy = "legacy"

    var label: String {
        switch self {
        case .systemStyle: return "中文日期（推荐）"
        case .legacy: return "Rune_时间戳"
        }
    }
}
