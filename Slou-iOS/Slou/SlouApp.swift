import SwiftUI
import UIKit
import Combine

@main
struct SlouApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        FontLoader.register()
        AudioSessionManager.shared.configure(voice: false)
        Haptics.shared.prepare()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(.white)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}

/// Корень: адрес сервера ещё не задан — экран настройки, задан — приложение
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if let url = model.serverURL {
                MainView(server: url)
                    .id(url.absoluteString)
                    .transition(.opacity)
            } else {
                SetupView(first: true)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.serverURL?.absoluteString ?? "")
        .sheet(isPresented: $model.showSettings) {
            SetupView(first: false)
                .environmentObject(model)
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
    }
}

/// Главный экран: весь «слоу» с сервера, поверх него — родные вещи айфона
struct MainView: View {
    let server: URL
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var web = WebController()
    @StateObject private var duel = DuelCenter()
    @State private var splashStart = Date()
    @State private var splashGone = false
    @State private var splashLeaving = false

    private var hideChrome: Bool { model.duel || model.immersive }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            WebView(controller: web)
                .ignoresSafeArea()
                .opacity(web.failure == nil ? 1 : 0)

            DuelLayer(center: duel)

            if let failure = web.failure {
                FailureView(message: failure,
                            retry: { web.reload() },
                            settings: { model.showSettings = true })
                    .transition(.opacity)
            }

            if !splashGone {
                SplashView(start: splashStart, leaving: splashLeaving)
                    .ignoresSafeArea()
                    .allowsHitTesting(!splashLeaving)
                    .transition(.opacity)
            }
        }
        .background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width > geo.size.height) { _, wide in
                    // повернули телефон боком в комнате — фильм на весь экран
                    guard UIDevice.current.userInterfaceIdiom == .phone, duel.arena == nil else { return }
                    web.setLandscape(wide)
                }
            }
        }
        .sheet(isPresented: $duel.arcadeOpen) {
            ArcadeSheet(center: duel)
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .slouShake)) { _ in openArcade() }
        .onChange(of: model.showArcade) { _, on in
            guard on else { return }
            model.showArcade = false
            openArcade()
        }
        .statusBarHidden(hideChrome)
        .persistentSystemOverlays(hideChrome ? .hidden : .automatic)
        .onAppear {
            web.attach(model)
            web.duel = duel
            duel.web = web
            duel.model = model
            web.open(server: server)
            if let path = model.pendingPath { web.open(path: path); model.pendingPath = nil }
        }
        .onChange(of: web.ready) { _, ready in if ready { leaveSplash() } }
        .onChange(of: web.failure) { _, failure in if failure != nil { leaveSplash(now: true) } }
        .onChange(of: model.pendingPath) { _, path in
            guard let path else { return }
            web.open(path: path)
            model.pendingPath = nil
        }
        .onChange(of: model.inRoom) { _, on in UIApplication.shared.isIdleTimerDisabled = on }
        .onChange(of: scenePhase) { _, phase in if phase == .active { web.resume() } }
    }

    /// Аркада: встряхнул телефон или открыл slou://arcade
    private func openArcade() {
        guard duel.arena == nil, duel.ceremony == nil, duel.ask == nil, !model.showSettings else { return }
        buzz("medium")
        duel.refreshFace()
        duel.arcadeOpen = true
    }

    /// Заставка держится, пока буквы не упадут и страница не будет готова
    private func leaveSplash(now: Bool = false) {
        guard !splashLeaving else { return }
        let wait = now ? 0 : max(0, 1.7 - Date().timeIntervalSince(splashStart))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            splashLeaving = true
            withAnimation(.easeInOut(duration: 0.5).delay(0.15)) { splashGone = true }
        }
    }
}
