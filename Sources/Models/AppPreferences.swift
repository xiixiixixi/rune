import Foundation
import AppKit
import SwiftUI

enum AppPreferences {
    // MARK: - Keys
    private static let appearanceKey = "bs_appAppearance"
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
    private static let recordingOpenEditorKey = "bs_recordingOpenEditor"
    private static let fileNameFormatKey = "bs_fileNameFormat"

    // MARK: - Appearance
    static var appearance: AppAppearance {
        get {
            guard let raw = UserDefaults.standard.string(forKey: appearanceKey),
                  let appearance = AppAppearance(rawValue: raw) else { return .system }
            return appearance
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    @MainActor
    static func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    // MARK: - General
    static var saveDirectory: String {
        get { UserDefaults.standard.string(forKey: saveDirKey) ?? NSHomeDirectory() + "/Desktop" }
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

    static var playSound: Bool {
        get { UserDefaults.standard.object(forKey: playSoundKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: playSoundKey) }
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

    static var recordingOpenEditor: Bool {
        get { UserDefaults.standard.object(forKey: recordingOpenEditorKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: recordingOpenEditorKey) }
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

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

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
