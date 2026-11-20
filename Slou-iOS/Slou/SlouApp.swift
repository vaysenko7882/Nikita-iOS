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
    @StateObject private var duel = DuelCenter()

    private var hideChrome: Bool {
        duel.arena != nil || duel.ceremony != nil || (!duel.demoRoomOpen && (model.duel || model.immersive))
    }

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if let url = model.serverURL {
                        MainView(server: url, duel: duel).id(url.absoluteString)
                    } else {
                        SetupView(first: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !model.inRoom && !model.immersive && !model.duel {
                    Button(action: duel.enterDemoRoom) {
                        HStack(spacing: 12) {
                            Image(systemName: "gamecontroller.fill")
                                .foregroundStyle(Color(hex: 0xefc767))
                            Text("Демо-комната").font(.headline)
                            Spacer()
                            Text("Играть с ботом").font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption.bold())
                        }
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 48)
                        .slouGlass(in: Capsule(), interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("demo.enter")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .frame(maxWidth: 580)
                }
            }
            .allowsHitTesting(!duel.demoRoomOpen && duel.arena == nil)
            .accessibilityHidden(duel.demoRoomOpen || duel.arena != nil || duel.ceremony != nil)
            if duel.demoRoomOpen {
                DemoRoomView(center: duel)
                    .allowsHitTesting(duel.arena == nil)
                    .accessibilityHidden(duel.arena != nil)
                    .transition(.opacity)
                    .zIndex(1)
            }
            DuelLayer(center: duel)
                .zIndex(2)
                .allowsHitTesting(duel.arena != nil || duel.ceremony != nil || duel.ask != nil || duel.toast != nil)
        }
        .animation(.easeInOut(duration: 0.35), value: model.serverURL?.absoluteString ?? "")
        .statusBarHidden(hideChrome)
        .persistentSystemOverlays(hideChrome ? .hidden : .automatic)
        .onAppear { duel.model = model }
        .onReceive(NotificationCenter.default.publisher(for: .slouShake)) { _ in
            if !model.showSettings { duel.enterDemoRoom() }
        }
        .onChange(of: model.requestsDemoRoom, initial: true) { _, requested in
            guard requested else { return }
            model.requestsDemoRoom = false
            duel.enterDemoRoom()
        }
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
    @ObservedObject var duel: DuelCenter
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var web = WebController()
    @State private var splashStart = Date()
    @State private var splashGone = false
    @State private var splashLeaving = false

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()

            WebView(controller: web)
                .ignoresSafeArea()
                .opacity(web.failure == nil ? 1 : 0)

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
        .onAppear {
            web.attach(model)
            web.duel = duel
            duel.web = web
            web.open(server: server)
            if let path = model.pendingPath { web.open(path: path); model.pendingPath = nil }
        }
        .onChange(of: web.ready) { _, ready in if ready { leaveSplash() } }
        .onChange(of: web.failure) { _, failure in if failure != nil { leaveSplash(now: true) } }
        .onChange(of: model.pendingPath) { _, path in
            guard let path else { return }
            duel.leaveDemoRoom()
            web.open(path: path)
            model.pendingPath = nil
        }
        .onChange(of: model.inRoom) { _, on in
            if duel.arena == nil { UIApplication.shared.isIdleTimerDisabled = on }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { web.resume() } }
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
