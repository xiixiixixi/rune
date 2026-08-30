import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var navigationModel: SettingsNavigationModel?
    private let lastSectionKey = "rune_lastSettingsSection"

    var isWindowVisible: Bool {
        window?.isVisible == true
    }

    private override init() { super.init() }

    func open(on screen: NSScreen? = nil, section: SettingsSection? = nil) {
        if let existing = window, existing.isVisible {
            if let section {
                navigationModel?.selection = section
            }
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let restoredSection = UserDefaults.standard.string(forKey: lastSectionKey)
            .flatMap(SettingsSection.init(rawValue:))
        let initialSection = section ?? restoredSection ?? .general
        let navigationModel = SettingsNavigationModel(initialSection: initialSection)
        navigationModel.onSelectionChange = { [weak self] selectedSection in
            self?.applySelection(selectedSection)
        }

        let hostingView = NSHostingView(
            rootView: PreferencesView(navigationModel: navigationModel)
        )

        // 顶部一级导航与内容区都由 Rune 自绘，系统标题栏只保留窗口控制。
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.title = initialSection.rawValue
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.backgroundColor = RuneTheme.nsBackground
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 1040, height: 680)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.transient, .moveToActiveSpace]

        centerOnCurrentScreen(win, preferring: screen)

        window = win
        self.navigationModel = navigationModel

        win.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 供设置页中的“开始截图 / 开始录屏”先收起自身，避免把设置窗口录进去。
    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        navigationModel = nil
        DispatchQueue.main.async {
            if !EditorWindowController.shared.hasOpenWindows
                && !VideoEditorWindowController.shared.hasOpenWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func applySelection(_ section: SettingsSection) {
        UserDefaults.standard.set(section.rawValue, forKey: lastSectionKey)
        window?.title = section.rawValue
    }

    private func centerOnCurrentScreen(_ window: NSWindow, preferring preferred: NSScreen? = nil) {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = preferred
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
