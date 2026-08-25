import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func open(on screen: NSScreen? = nil, section: SettingsSection? = nil) {
        if let existing = window, existing.isVisible {
            if let section {
                let hostingView = NSHostingView(
                    rootView: PreferencesView(initialSection: section).runeTypography()
                )
                hostingView.appearance = NSAppearance(named: .aqua)
                existing.contentView = hostingView
            }
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(
            rootView: PreferencesView(initialSection: section ?? .general).runeTypography()
        )
        hostingView.appearance = NSAppearance(named: .aqua)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.title = "Rune 设置"
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .aqua)
        win.backgroundColor = RuneTheme.nsPaperBackground
        win.minSize = NSSize(width: 980, height: 700)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.transient, .moveToActiveSpace]

        centerOnCurrentScreen(win, preferring: screen)

        window = win

        win.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.async {
            if !EditorWindowController.shared.hasOpenWindows
                && !VideoEditorWindowController.shared.hasOpenWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
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
