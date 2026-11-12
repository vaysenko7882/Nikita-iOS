import SwiftUI

@main
struct AutismexApp: App {
    @StateObject private var store = PresenceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .tint(Palette.on)
        }
    }
}
