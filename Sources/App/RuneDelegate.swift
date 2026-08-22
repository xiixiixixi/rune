import AppKit

@MainActor
final class RuneDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ExceptionLogger.install()
        AppPreferences.applyAppearance()
        NSApp.setActivationPolicy(.accessory)

        MenuBarPopoverController.shared.setup()

        // M1 §5：改用 Carbon RegisterEventHotKey，不再需要辅助功能权限，直接注册。
        ShortcutService.shared.registerAll()

        // 后台预热截图引擎（屏幕清单缓存 + 采集管线），首次截图免卡顿
        CaptureOrchestrator.shared.prewarm()
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
