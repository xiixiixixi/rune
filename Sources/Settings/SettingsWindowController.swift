import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var navigationModel: SettingsNavigationModel?
    private let toolbarIdentifier = NSToolbar.Identifier("Rune.Settings.Toolbar")
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

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.title = initialSection.rawValue
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.backgroundColor = .windowBackgroundColor
        win.minSize = NSSize(width: 880, height: 640)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.transient, .moveToActiveSpace]
        win.toolbarStyle = .preference

        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = initialSection.toolbarIdentifier
        win.toolbar = toolbar

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
        window?.toolbar?.selectedItemIdentifier = section.toolbarIdentifier
    }

    @objc private func selectToolbarItem(_ sender: NSToolbarItem) {
        guard let section = SettingsSection(toolbarIdentifier: sender.itemIdentifier) else { return }
        navigationModel?.selection = section
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(\.toolbarIdentifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(\.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsSection.allCases.map(\.toolbarIdentifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let section = SettingsSection(toolbarIdentifier: itemIdentifier) else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = section.rawValue
        item.paletteLabel = section.rawValue
        item.toolTip = section.toolbarHelp
        item.image = NSImage(
            systemSymbolName: section.icon,
            accessibilityDescription: section.rawValue
        )
        item.target = self
        item.action = #selector(selectToolbarItem(_:))
        return item
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
