import SwiftUI

@main
struct RippleLauncher {
    @MainActor
    static func main() {
        L10n.configureProcessLanguage()
        RippleApp.main()
    }
}

struct RippleApp: App {
    @StateObject private var settings = WorkspaceSettings()
    var body: some Scene {
        WindowGroup(L10n.appName) {
            ContentView()
                .environmentObject(settings)
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
        Settings {
            ModeSettingsView()
                .environmentObject(settings)
                .environment(\.locale, L10n.locale)
        }
    }
}
