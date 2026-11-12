import SwiftUI
import UIKit

enum ActiveSheet: Identifiable {
    case site
    case share(URL)
    case datePicker

    var id: String {
        switch self {
        case .site: return "site"
        case .share(let url): return "share-" + url.absoluteString
        case .datePicker: return "date"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: PresenceStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrubbing = false
    @State private var diagnosticsOpen = false
    @State private var sheet: ActiveSheet?
    @State private var toast: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.page.ignoresSafeArea()
            if let state = store.state {
                content(state)
                DateBar(state: state, onPickDate: { sheet = .datePicker })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            } else {
                LaunchView(message: store.errorMessage) {
                    Task { await store.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let toast {
                ToastView(text: toast)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { store.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: store.start()
            case .background: store.stop()
            default: break
            }
        }
        .sheet(item: $sheet) { item in
            sheetView(item)
        }
    }

    private func content(_ state: PresenceState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TopBar(
                        onConnection: {
                            diagnosticsOpen = true
                            withAnimation(.snappy) { proxy.scrollTo("diagnostics", anchor: .center) }
                        },
                        onExport: export,
                        onSite: { sheet = .site }
                    )
                    ForEach(store.notices, id: \.self) { text in
                        NoticeView(text: text).padding(.bottom, 10)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        StatusCard(state: state, date: context.date)
                    }
                    DaySection(state: state, scrubbing: $scrubbing)
                        .id("day")
                        .padding(.top, 52)
                    WeekSection(state: state)
                        .padding(.top, 60)
                    ChronicleSection(state: state)
                        .padding(.top, 60)
                    HistorySection(state: state) {
                        withAnimation(.snappy) { proxy.scrollTo("day", anchor: .top) }
                    }
                    .padding(.top, 60)
                    TotalsCard(state: state)
                        .padding(.top, 60)
                    DiagnosticsCard(state: state, isOpen: $diagnosticsOpen, onCopy: copyDiagnostics)
                        .id("diagnostics")
                        .padding(.top, 12)
                    FooterView(state: state)
                        .padding(.top, 36)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(scrubbing)
            .refreshable { await store.refresh() }
        }
    }

    @ViewBuilder
    private func sheetView(_ item: ActiveSheet) -> some View {
        switch item {
        case .site:
            SafariView(url: PresenceAPI.defaultBase)
                .ignoresSafeArea()
        case .share(let url):
            ShareSheet(items: [url])
                .presentationDetents([.medium, .large])
        case .datePicker:
            if let state = store.state {
                DatePickerSheet(state: state) { day in
                    sheet = nil
                    store.pick(day)
                }
            }
        }
    }

    private func export() {
        Task {
            do {
                let url = try await store.api.exportCSV()
                sheet = .share(url)
            } catch {
                show("Не удалось выгрузить CSV")
            }
        }
    }

    private func copyDiagnostics() {
        Task {
            do {
                UIPasteboard.general.string = try await store.api.diagnostics()
                show("Диагностика скопирована. Ключей и сессии в ней нет.")
            } catch {
                show("Не удалось скопировать диагностику")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.snappy) {
                if toast == text { toast = nil }
            }
        }
    }
}

// MARK: Верхняя строка

struct TopBar: View {
    @EnvironmentObject private var store: PresenceStore
    let onConnection: () -> Void
    let onExport: () -> Void
    let onSite: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let connected = store.isConnected(at: context.date)
            let good = connected && (store.state?.health?.connected ?? true) && store.liveState(at: context.date) != "unknown"
            let label = !connected ? "Связь потеряна" : (good ? "Наблюдение идёт" : "Нет точных данных")
            HStack {
                Button(action: onConnection) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(good ? Palette.on : Palette.warn)
                            .frame(width: 7, height: 7)
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(Palette.panel, in: Capsule())
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Экспорт CSV", systemImage: "square.and.arrow.down", action: onExport)
                    Button("Открыть сайт", systemImage: "safari", action: onSite)
                    Button("Обновить", systemImage: "arrow.clockwise") {
                        Task { await store.refresh() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 34, height: 34)
                        .background(Palette.panel, in: Circle())
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
    }
}

// MARK: Экран загрузки

struct LaunchView: View {
    let message: String?
    var retry: () -> Void
    @State private var spin = false

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(Palette.off, lineWidth: 10)
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Palette.on, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
            }
            .frame(width: 88, height: 88)
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true }
            }
            Text(message == nil ? "Подключаемся…" : "Нет связи с сервером")
                .font(.rounded(24))
                .foregroundStyle(Palette.ink)
            if let message {
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button(action: retry) {
                    Text("Повторить")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.page)
                        .padding(.horizontal, 28)
                        .frame(height: 50)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
    }
}

struct FooterView: View {
    let state: PresenceState

    var body: some View {
        let poll = Int(state.health?.pollSeconds ?? 1)
        Text("Presence 2.0. События Telegram и сверка каждые \(poll) с, пока API доступен. Telegram может задержать или скрыть статус. Паузы по Last Seen помечены отдельно.")
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
