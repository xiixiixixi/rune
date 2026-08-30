import AppKit
import SwiftUI

@MainActor
final class CaptureLibraryWindowController: NSObject, NSWindowDelegate {
    static let shared = CaptureLibraryWindowController()

    private var window: NSWindow?

    var isWindowVisible: Bool {
        window?.isVisible == true
    }

    private override init() { super.init() }

    func open(on screen: NSScreen? = nil, searchQuery: String = "") {
        if let window, window.isVisible {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingView(
            rootView: CaptureLibraryView(initialSearchText: searchQuery)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "素材库"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.backgroundColor = RuneTheme.nsBackground
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1040, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace]

        center(window, on: screen)
        self.window = window

        NSApp.setActivationPolicy(.regular)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        DispatchQueue.main.async {
            if !SettingsWindowController.shared.isWindowVisible
                && !EditorWindowController.shared.hasOpenWindows
                && !VideoEditorWindowController.shared.hasOpenWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func center(_ window: NSWindow, on preferredScreen: NSScreen?) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = preferredScreen
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let frame = screen.visibleFrame
        window.setFrameOrigin(
            NSPoint(
                x: frame.midX - window.frame.width / 2,
                y: frame.midY - window.frame.height / 2
            )
        )
    }
}
