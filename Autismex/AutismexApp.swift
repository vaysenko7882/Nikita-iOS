import SwiftUI

@main
@MainActor
struct AutismexApp: App {
    @State private var store = PresenceStore()
    @State private var interaction = Interaction()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(interaction)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .tint(Palette.on)
        }
    }
}
