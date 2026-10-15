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
    var body: some Scene {
        WindowGroup(L10n.appName) {
            ContentView()
                .environment(\.locale, L10n.locale)
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
