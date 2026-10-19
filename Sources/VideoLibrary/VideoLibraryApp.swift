import SwiftUI

@main
struct VideoLibraryApp: App {
    @State private var store: LibraryStore
    @State private var suggestionsStore: YouTubeSuggestionsStore
    @AppStorage("playerOpensFullScreen") private var playerOpensFullScreen = false

    init() {
        // Encrypt any plaintext secrets left by older versions before
        // anything reads them.
        SecurityCheck.shared.migrateAtLaunch()
        _store = State(initialValue: LibraryStore())
        _suggestionsStore = State(initialValue: YouTubeSuggestionsStore())

        // Cookie settings used to be separate for Suggestions; carry them over.
        let defaults = UserDefaults.standard
        for (old, new) in [("suggestionsBrowserCookies", AppPreference.browserCookies),
                           ("suggestionsRememberCookies", AppPreference.rememberCookies)]
        where defaults.object(forKey: new) == nil {
            if let value = defaults.object(forKey: old) { defaults.set(value, forKey: new) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(suggestionsStore: suggestionsStore)
                .environment(store)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Toggle("Open Videos in Full Screen", isOn: $playerOpensFullScreen)
            }
        }

        Window("Sign In to YouTube", id: YouTubeSignInView.windowID) {
            YouTubeSignInView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(suggestionsStore: suggestionsStore)
                .environment(store)
        }
    }
}
