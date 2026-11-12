import SwiftUI
import WebKit
import UIKit

private enum PresenceStyle {
    static let green = Color(red: 0.12, green: 0.69, blue: 0.32)
    static let muted = Color.secondary
    static func color(_ state: String) -> Color {
        state == "online" ? green : state == "offline" ? .secondary : .orange
    }
    static func title(_ state: String) -> String {
        state == "online" ? "В сети" : state == "offline" ? "Не в сети" : "Нет данных"
    }
}

private func duration(_ value: Double, seconds: Bool = false) -> String {
    let n = max(0, Int(value.isFinite ? value : 0))
    if n >= 86400 { return "\(n / 86400) д \((n % 86400) / 3600) ч" }
    if n >= 3600 { return "\(n / 3600) ч \((n % 3600) / 60) мин" }
    if n >= 60 { return seconds ? "\(n / 60) мин \(n % 60) с" : "\(n / 60) мин" }
    return "\(n) с"
}

private func clock(_ timestamp: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: Date(timeIntervalSince1970: timestamp))
}

private func dayTitle(_ value: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.timeZone = TimeZone(identifier: "Europe/Moscow")
    formatter.dateFormat = "yyyy-MM-dd"
    guard let date = formatter.date(from: value) else { return value }
    formatter.dateFormat = "d MMMM"
    return formatter.string(from: date)
}

private struct GlassSurface: ViewModifier {
    let radius: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        #else
        content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        #endif
    }
}

private extension View {
    func glassCard(_ radius: CGFloat = 24) -> some View { modifier(GlassSurface(radius: radius)) }
}

struct ContentView: View {
    @StateObject private var model = PresenceModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { OverviewScreen(model: model) }
                .tabItem { Label("Обзор", systemImage: "circle.dotted.circle") }.tag(0)
            NavigationStack {
                HistoryScreen(model: model) { selectedTab = 0 }
            }
            .tabItem { Label("История", systemImage: "clock.arrow.circlepath") }.tag(1)
            NavigationStack { WebsiteScreen(url: model.baseURL) }
                .tabItem { Label("Весь сайт", systemImage: "safari") }.tag(2)
        }
        .tint(PresenceStyle.green)
        .task(id: scenePhase) {
            if scenePhase == .active { await model.run() }
        }
    }
}

private struct OverviewScreen: View {
    @ObservedObject var model: PresenceModel

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                if let snapshot = model.snapshot {
                    if snapshot.demo == true {
                        NoticeCard(text: "Сервер сейчас отдаёт демонстрационные данные.", icon: "info.circle")
                    }
                    if let error = model.errorMessage {
                        NoticeCard(text: error, icon: "wifi.exclamationmark")
                    }
                    if !["tracking", "demo"].contains(snapshot.health.mode), let message = snapshot.health.message {
                        NoticeCard(text: message, icon: "info.circle")
                    }
                    ProfileCard(model: model, snapshot: snapshot)
                    DayPicker(model: model, snapshot: snapshot)
                    RingCard(snapshot: snapshot)
                    MetricsGrid(snapshot: snapshot)
                    RecentIntervals(snapshot: snapshot)
                    ConnectionCard(snapshot: snapshot, lastSuccess: model.lastSuccess)
                } else if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Нет связи с сервером", systemImage: "wifi.exclamationmark")
                    } description: { Text(error) } actions: {
                        Button("Повторить") { Task { await model.refresh() } }.buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 50)
                } else {
                    ProgressView("Подключаем Autismex…").padding(.vertical, 100)
                }
                Text("Сбор статистики работает на VPS круглосуточно. Приложение обновляет данные, пока открыто. Время — московское.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.bottom, 18)
            }
            .padding(.horizontal, 20).padding(.top, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Присутствие")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Обновить данные")
            }
        }
        .refreshable { await model.refresh() }
    }
}

private struct NoticeCard: View {
    let text: String
    let icon: String
    var body: some View {
        Label(text, systemImage: icon).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(16).glassCard(18)
    }
}

private struct ProfileCard: View {
    @ObservedObject var model: PresenceModel
    let snapshot: PresenceSnapshot

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = model.displayState(at: context.date)
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    AsyncImage(url: model.baseURL.appendingPathComponent("api/avatar")) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack {
                            Circle().fill(PresenceStyle.green.opacity(0.12))
                            Image(systemName: "person.fill").foregroundStyle(PresenceStyle.green).font(.title2)
                        }
                    }
                    .frame(width: 58, height: 58).clipShape(Circle())
                    .overlay(Circle().stroke(PresenceStyle.color(state).opacity(0.7), lineWidth: 2).padding(-4))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(snapshot.profile.name ?? "Мой аккаунт").font(.headline)
                        Text("@\(snapshot.profile.username ?? "nelaskowaa")").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle().fill(PresenceStyle.color(state)).frame(width: 11, height: 11)
                        Text(PresenceStyle.title(state)).font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(state == "online" ? PresenceStyle.green : .primary)
                    }
                    if state == "unknown" {
                        Text(model.sourceFresh(at: context.date) ? (snapshot.current.reason ?? "Ждём точный статус Telegram") : "Ждём свежее подтверждение сервера")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("\(state == "online" ? "Онлайн" : "Пауза") \(duration(model.elapsedStatus(at: context.date), seconds: true))")
                            .font(.title3).monospacedDigit().foregroundStyle(.secondary)
                        if state == "offline" && snapshot.current.pauseSource == "telegram_last_seen" {
                            Text("С \(clock(snapshot.current.pauseSince ?? snapshot.current.since)) · начало по Last Seen Telegram")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(23).glassCard(28)
        }
    }
}

private struct DayPicker: View {
    @ObservedObject var model: PresenceModel
    let snapshot: PresenceSnapshot
    var body: some View {
        HStack {
            Button { Task { await model.changeDay(-1) } } label: { Image(systemName: "chevron.left").frame(width: 38, height: 38) }
                .accessibilityLabel("Предыдущий день")
            Spacer()
            Button { Task { await model.selectToday() } } label: {
                VStack(spacing: 3) {
                    Text(snapshot.date == snapshot.today ? "Сегодня" : dayTitle(snapshot.date)).font(.headline)
                    Text(snapshot.date == snapshot.today ? dayTitle(snapshot.date) : "Нажми, чтобы вернуться к сегодня")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { Task { await model.changeDay(1) } } label: { Image(systemName: "chevron.right").frame(width: 38, height: 38) }
                .disabled(snapshot.date >= snapshot.today).accessibilityLabel("Следующий день")
        }
    }
}

private struct RingCard: View {
    let snapshot: PresenceSnapshot
    private var span: Double { max(1, snapshot.day.end - snapshot.day.start) }
    private func position(_ value: Double) -> CGFloat { CGFloat(min(1, max(0, (value - snapshot.day.start) / span))) }

    var body: some View {
        VStack(spacing: 17) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.08), lineWidth: 12)
                ForEach(Array(snapshot.intervals.enumerated()), id: \.offset) { _, interval in
                    Circle().trim(from: position(interval.start), to: position(interval.end))
                        .stroke(PresenceStyle.color(interval.state).opacity(interval.state == "online" ? 1 : 0.27),
                                style: StrokeStyle(lineWidth: interval.state == "online" ? 15 : 5,
                                                   lineCap: .round, dash: interval.state == "unknown" ? [2, 5] : []))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 7) {
                    Text("В сети за день").font(.subheadline).foregroundStyle(.secondary)
                    Text(duration(snapshot.day.onlineSeconds)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("00 · 06 · 12 · 18 · 24").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 232, height: 232).padding(.vertical, 12)
            HStack(spacing: 19) {
                RingLegend(text: "В сети", color: PresenceStyle.green)
                RingLegend(text: "Офлайн", color: .secondary)
                RingLegend(text: "Нет данных", color: .orange)
            }
            Text("Данные за \(Int(snapshot.day.coveragePercent.rounded()))% прошедшего времени суток")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 20).glassCard(28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Циферблат дня. Наблюдаемое время онлайн: \(duration(snapshot.day.onlineSeconds)). Покрытие: \(Int(snapshot.day.coveragePercent)) процентов.")
    }
}

private struct RingLegend: View {
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(text).font(.caption2).foregroundStyle(.secondary) }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer(minLength: 4); Image(systemName: icon).font(.caption).foregroundStyle(PresenceStyle.green) }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(17).glassCard(21)
    }
}

private struct MetricsGrid: View {
    let snapshot: PresenceSnapshot
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(title: "Онлайн-сеансы", value: "\(snapshot.day.sessionCount)", icon: "waveform.path")
            MetricTile(title: "Паузы", value: "\(snapshot.day.pauseCount)", icon: "pause")
            MetricTile(title: "Самая долгая пауза", value: duration(snapshot.day.maxPauseSeconds), icon: "clock")
            MetricTile(title: "Без данных", value: duration(snapshot.day.unknownSeconds), icon: "questionmark.circle")
        }
    }
}

private struct RecentIntervals: View {
    let snapshot: PresenceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Хроника дня").font(.title3.bold())
            if snapshot.intervals.isEmpty {
                Text("За этот день пока нет наблюдений").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.intervals.suffix(8).reversed().enumerated()), id: \.offset) { _, interval in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(PresenceStyle.color(interval.state)).frame(width: 7, height: 7).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PresenceStyle.title(interval.state)).font(.subheadline.weight(.medium))
                        Text("\(clock(interval.start)) — \(interval.ongoing && snapshot.date == snapshot.today ? "сейчас" : clock(interval.end))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(duration(interval.duration, seconds: interval.duration < 3600)).font(.subheadline).monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20).glassCard()
    }
}

private struct ConnectionCard: View {
    let snapshot: PresenceSnapshot
    let lastSuccess: Date?
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(snapshot.health.message ?? "Ожидаем данные Telegram")
                Text("Интервал API: \(snapshot.health.pollSeconds ?? 0, specifier: "%.0f") с")
                if let ms = snapshot.health.rpcLatencyMs { Text("Ответ API: \(ms, specifier: "%.0f") мс") }
                if let timestamp = snapshot.current.lastObserved { Text("Подтверждение: \(clock(timestamp)) МСК") }
                Text("ID аккаунта: \(String(snapshot.profile.id))")
            }
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        } label: { Label("Связь с сервером", systemImage: "antenna.radiowaves.left.and.right").font(.subheadline) }
        .padding(18).glassCard(20)
    }
}

private struct HistoryScreen: View {
    @ObservedObject var model: PresenceModel
    let onSelect: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let snapshot = model.snapshot {
                    MetricTile(title: "Наблюдаемый онлайн за всё время", value: duration(snapshot.total.onlineSeconds), icon: "chart.bar.fill")
                    HStack(spacing: 12) {
                        MetricTile(title: "Сеансы", value: "\(snapshot.total.sessionCount)", icon: "waveform.path")
                        MetricTile(title: "Макс. пауза", value: duration(snapshot.total.maxPauseSeconds), icon: "clock")
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(snapshot.history.enumerated()), id: \.offset) { index, day in
                            Button {
                                Task { await model.selectDate(day.date); onSelect() }
                            } label: {
                                HistoryRow(date: day.date, onlineSeconds: day.onlineSeconds, count: day.sessionCount, pauses: day.pauseCount, coverage: day.coveragePercent)
                            }
                            .buttonStyle(.plain)
                            if index < snapshot.history.count - 1 { Divider().padding(.horizontal, 18) }
                        }
                    }
                    .glassCard()
                    ShareLink(item: model.baseURL.appendingPathComponent("api/export.csv")) { Label("Экспорт всей истории CSV", systemImage: "square.and.arrow.up") }
                        .font(.subheadline).padding()
                } else {
                    ContentUnavailableView("История ещё не загружена", systemImage: "clock", description: Text("Открой обзор или обнови данные."))
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("История")
        .refreshable { await model.refresh() }
    }
}

private struct HistoryRow: View {
    let date: String
    let onlineSeconds: Double
    let count: Int
    let pauses: Int
    let coverage: Double
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(dayTitle(date)).font(.headline)
                Text("Сеансы: \(count) · паузы: \(pauses)").font(.caption).foregroundStyle(.secondary)
                Text("Данные: \(Int(coverage.rounded()))%").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text(duration(onlineSeconds)).font(.system(.headline, design: .rounded)).monospacedDigit()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(18).contentShape(Rectangle())
    }
}

private struct WebsiteScreen: View {
    let url: URL
    @State private var loading = true
    @State private var error: String?
    @State private var reloadID = UUID()
    var body: some View {
        ZStack {
            WebsiteView(url: url, loading: $loading, error: $error).id(reloadID)
            if loading { ProgressView().padding(18).glassCard(18) }
            if let error {
                ContentUnavailableView {
                    Label("Сайт недоступен", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("Повторить") { self.error = nil; loading = true; reloadID = UUID() }
                }
                .background(Color(uiColor: .systemBackground))
            }
        }
        .navigationTitle("Autismex").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { error = nil; loading = true; reloadID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Перезагрузить сайт")
            }
        }
    }
}

private struct WebsiteView: UIViewRepresentable {
    let url: URL
    @Binding var loading: Bool
    @Binding var error: String?
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        web.load(URLRequest(url: url))
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebsiteView
        init(parent: WebsiteView) { self.parent = parent }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.loading = false; parent.error = nil }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.loading = false; parent.error = "Проверь интернет и доступность autismex.best."
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.loading = false; parent.error = "Не удалось загрузить страницу."
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
            if target.scheme == "about" || (target.scheme == "https" && target.host == parent.url.host) {
                decisionHandler(.allow)
            } else {
                if navigationAction.navigationType == .linkActivated && ["https", "http", "tg"].contains(target.scheme ?? "") {
                    UIApplication.shared.open(target)
                }
                decisionHandler(.cancel)
            }
        }
    }
}
