import SwiftUI

@main
struct RuneApp: App {
    @NSApplicationDelegateAdaptor(RuneDelegate.self) var delegate

    var body: some Scene {
        Settings {
            PreferencesView()
                .runeTypography()
                .tint(RuneTheme.accent)
        }
    }
}
