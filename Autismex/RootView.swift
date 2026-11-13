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
    @Environment(PresenceStore.self) private var store
    @Environment(Interaction.self) private var interaction
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrubbing = false
    @State private var diagnosticsOpen = false
    @State private var sheet: ActiveSheet?
    @State private var toast: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.page.ignoresSafeArea()
            if let state = store.state {
                GeometryReader { geometry in
                    content(state, width: max(1, geometry.size.width))
                }
                DateBar(state: state, onPickDate: { sheet = .datePicker })
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                MiniStatus()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 4)
            } else {
                LaunchView(message: store.errorMessage) {
                    Task { await store.refresh(force: true) }
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

    /// Единственная прокрутка — вертикальная. Ширина содержимого жёстко равна ширине
    /// экрана, поэтому сдвинуть или «растянуть» экран вбок нельзя.
    /// Порядок — от близкого к далёкому: сейчас → выбранный день → неделя → месяц → всё время.
    private func content(_ state: PresenceState, width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id("top")
                    ForEach(store.notices, id: \.self) { text in
                        NoticeView(text: text).padding(.bottom, 10)
                    }
                    StatusCard(
                        state: state,
                        onShare: shareDay,
                        onExport: export,
                        onSite: { sheet = .site },
                        onDiagnostics: {
                            diagnosticsOpen = true
                            withAnimation(.snappy) { proxy.scrollTo("diagnostics", anchor: .center) }
                        }
                    )
                    DaySection(state: state, scrubbing: $scrubbing)
                        .padding(.top, 44)
                        .id("day")
                    ChronicleSection(state: state, width: width - 40)
                        .padding(.top, 40)
                    WeekSection(state: state)
                        .padding(.top, 56)
                    HistorySection(state: state) {
                        interaction.scroll(to: "day")
                    }
                    .padding(.top, 56)
                    TotalsCard(state: state)
                        .padding(.top, 56)
                    DiagnosticsCard(state: state, isOpen: $diagnosticsOpen, onCopy: copyDiagnostics)
                        .id("diagnostics")
                        .padding(.top, 12)
                    FooterView(state: state)
                        .padding(.top, 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 110)
                .frame(width: width)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDisabled(scrubbing)
            .modifier(HeroTracker(interaction: interaction))
            .refreshable { await store.refresh(force: true) }
            .onChange(of: interaction.scrollRequest) { _, request in
                withAnimation(.snappy) {
                    proxy.scrollTo(request.target, anchor: request.target == "dial" ? .center : .top)
                }
            }
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

    /// Картинка дня: циферблат и итог. Имя и ник на неё не попадают.
    private func shareDay() {
        guard let state = store.state else { return }
        let metrics = store.liveMetrics(at: Date()).day
        let sessions = Int(metrics.sessions)
        let card = DayShareCard(
            title: Fmt.cap(Fmt.dayText(state.date, "d MMMM, EEEE")),
            online: Fmt.duration(metrics.online),
            caption: String(sessions) + " " + Fmt.plural(sessions, "сеанс", "сеанса", "сеансов") + " в сети",
            segments: state.rows.map { DialSegment(state: $0.state, start: $0.start, end: store.liveEnd($0)) },
            dayStart: state.dayStart,
            dayEnd: state.dayEnd
        )
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let data = renderer.uiImage?.pngData() else {
            show("Не удалось собрать картинку")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("autismex-" + state.date + ".png")
        do {
            try data.write(to: url, options: .atomic)
            sheet = .share(url)
        } catch {
            show("Не удалось собрать картинку")
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
                show("Диагностика скопирована")
            } catch {
                show("Не удалось скопировать диагностику")
            }
        }
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.snappy) {
                if toast == text { toast = nil }
            }
        }
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
        Text("Presence 2.3. Время: " + zoneText)
            .font(.system(size: 12))
            .foregroundStyle(Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var zoneText: String {
        let tz = state.tz
        let hours = tz.secondsFromGMT() / 3600
        let city: String
        if tz.identifier == "Europe/Moscow" {
            city = "Москва"
        } else {
            city = tz.identifier.split(separator: "/").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? tz.identifier
        }
        return city + ", UTC" + (hours >= 0 ? "+" : "−") + String(abs(hours))
    }
}
