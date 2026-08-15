import AppKit

@MainActor
final class BetterShotDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPreferences.applyAppearance()
        NSApp.setActivationPolicy(.accessory)

        MenuBarPopoverController.shared.setup()

        // M1 §5：改用 Carbon RegisterEventHotKey，不再需要辅助功能权限，直接注册。
        ShortcutService.shared.registerAll()
    }


    func applicationWillTerminate(_ notification: Notification) {
        ShortcutService.shared.unregisterAll()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }
}
