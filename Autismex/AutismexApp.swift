import SwiftUI

@main
@MainActor
struct AutismexApp: App {
    @State private var store = PresenceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .tint(Palette.on)
        }
    }
}
