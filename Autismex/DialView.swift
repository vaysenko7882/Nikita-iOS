import SwiftUI
import UIKit

struct DialInspection: Equatable {
    var t: Double
    var rowStart: Double?
    var future: Bool
}

/// Canvas с анимируемой прорисовкой кольца по часовой стрелке.
struct DialCanvas: View, Animatable {
    var sweep: Double
    let segments: [DialSegment]
    let dayStart: Double
    let dayEnd: Double
    var habit: [Double]? = nil

    var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }

    var body: some View {
        Canvas { context, size in
            DialPainter.paint(&context, size: size, segments: segments, dayStart: dayStart, dayEnd: dayEnd, sweep: sweep, habit: habit)
        }
    }
}

/// Бегунок «сейчас» на кольце.
struct NowKnob: View {
    let state: String

    var body: some View {
        ZStack {
            if state == "online" {
                PulseHalo()
            }
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.28), radius: 1.6, x: 0, y: 1)
            Group {
                if state == "online" {
                    Circle().fill(Palette.on)
                } else if state == "offline" {
                    Circle().fill(Palette.offDot)
                } else {
                    Circle().strokeBorder(Palette.ink3, style: StrokeStyle(lineWidth: 1.6, dash: [2.2, 2]))
                }
            }
            .padding(6)
        }
    }
}

/// Прозрачный слой касаний поверх циферблата на жестах UIKit.
/// Долгое нажатие (0,18 с) начинает разбор времени, обычное движение пальца сразу
/// достаётся прокрутке страницы — она не ждёт и не «залипает».
struct DialTouchLayer: UIViewRepresentable {
    var onScrub: (CGPoint, Bool) -> Void
    var onScrubEnd: () -> Void
    var onTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0.18
        press.allowableMovement = 12
        view.addGestureRecognizer(press)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: DialTouchLayer

        init(_ parent: DialTouchLayer) {
            self.parent = parent
        }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                parent.onScrub(point, true)
            case .changed:
                parent.onScrub(point, false)
            case .ended, .cancelled, .failed:
                parent.onScrubEnd()
            default:
                break
            }
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            parent.onTap(recognizer.location(in: recognizer.view))
        }
    }
}

/// Циферблат суток. Удержание и ведение пальцем — разбор времени с тактильным щелчком
/// на каждом отрезке. Короткое касание кольца — отрезок под пальцем.
struct DialView: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    @Binding var scrubbing: Bool
    var onLearned: () -> Void = {}

    @State private var inspection: DialInspection?
    @State private var releaseTask: Task<Void, Never>?
    @State private var sweep: Double = 0
    @State private var knobShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dayStart: Double { state.dayStart }
    private var dayEnd: Double { state.dayEnd }

    var body: some View {
        GeometryReader { geometry in
            let side = max(1, min(geometry.size.width, geometry.size.height))
            ZStack {
                // Кольцо перерисовывается раз в 30 секунд: за это время дуга сдвигается меньше чем на пиксель.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ring(side: side, date: context.date)
                }
                if let inspection {
                    needle(for: inspection.t, side: side)
                }
                DialCenter(state: state, inspection: inspection, scale: side / 340)
                    .frame(width: side * 0.58)
            }
            .frame(width: side, height: side)
            .overlay(
                DialTouchLayer(
                    onScrub: { point, began in
                        if began { scrubbing = true }
                        inspect(at: point, side: side, requireRing: false)
                    },
                    onScrubEnd: {
                        scrubbing = false
                        onLearned()
                        release(after: 1.8)
                    },
                    onTap: { point in
                        if inspect(at: point, side: side, requireRing: true) {
                            release(after: 2.6)
                        } else if inspection != nil {
                            release(after: 0)
                        }
                    }
                )
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: inspection?.rowStart ?? -1) { _, new in new != -1 }
        .sensoryFeedback(.impact(weight: .light), trigger: scrubbing) { _, isOn in isOn }
        .onAppear { runSweep() }
        .onChange(of: state.date) { _, _ in
            inspection = nil
            runSweep()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Циферблат дня. В сети " + Fmt.duration(store.liveMetrics(at: Date()).day.online)))
    }

    // MARK: Рисование

    private func ring(side: CGFloat, date: Date) -> some View {
        let now = store.serverNow(at: date)
        let segments = state.rows.map { row in
            DialSegment(state: row.state, start: row.start, end: store.liveEnd(row, at: date))
        }
        return ZStack {
            DialCanvas(sweep: sweep, segments: segments, dayStart: dayStart, dayEnd: dayEnd, habit: Insights.habit(state: state))
            if state.isToday {
                NowKnob(state: store.liveState(at: date))
                    .frame(width: 24 * side / 340, height: 24 * side / 340)
                    .position(point(for: min(now, dayEnd), side: side))
                    .opacity(knobShown ? 1 : 0)
            }
        }
    }

    private func point(for t: Double, side: CGFloat, radius: CGFloat = 128) -> CGPoint {
        Dial.point(Dial.angle(t, start: dayStart, end: dayEnd), radius * side / 340, CGPoint(x: side / 2, y: side / 2))
    }

    private func needle(for t: Double, side: CGFloat) -> some View {
        let a = Dial.angle(t, start: dayStart, end: dayEnd)
        let center = CGPoint(x: side / 2, y: side / 2)
        let u = side / 340
        return Path { path in
            path.move(to: Dial.point(a, 108 * u, center))
            path.addLine(to: Dial.point(a, 148 * u, center))
        }
        .stroke(Palette.ink, style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }

    // MARK: Разбор времени

    @discardableResult
    private func inspect(at location: CGPoint, side: CGFloat, requireRing: Bool) -> Bool {
        let u = Double(side) / 340
        let dx = Double(location.x) - Double(side) / 2
        let dy = Double(location.y) - Double(side) / 2
        let radius = (dx * dx + dy * dy).squareRoot() / u
        if requireRing && (radius < 92 || radius > 172) { return false }
        releaseTask?.cancel()

        var angle = atan2(dy, dx) + Double.pi / 2
        if angle < 0 { angle += Dial.tau }
        let span = dayEnd - dayStart
        var t = min(max(dayStart + angle / Dial.tau * span, dayStart), dayEnd - 1)
        let limit = state.isToday ? store.serverNow() : dayEnd
        if t > limit {
            inspection = DialInspection(t: t, rowStart: nil, future: true)
            return true
        }
        let slack = 14 / u / 128 / Dial.tau * span
        let row = interval(at: t, slack: slack)
        if let row { t = min(max(t, row.start), store.liveEnd(row)) }
        inspection = DialInspection(t: t, rowStart: row?.start, future: false)
        return true
    }

    /// Отрезок под пальцем; короткие сеансы онлайн «притягивают» в радиусе 14 pt.
    private func interval(at t: Double, slack: Double) -> Interval? {
        var best: Interval?
        var distance = Double.infinity
        for row in state.rows where row.state == "online" {
            let end = store.liveEnd(row)
            let d = t < row.start ? row.start - t : (t > end ? t - end : 0)
            if d <= slack && d < distance {
                best = row
                distance = d
            }
        }
        if let best { return best }
        return state.rows.first(where: { t >= $0.start && t < store.liveEnd($0) })
    }

    private func release(after seconds: Double) {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor in
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { inspection = nil }
        }
    }

    private func runSweep() {
        if reduceMotion {
            sweep = 1
            knobShown = true
            return
        }
        sweep = 0
        knobShown = false
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.3, 0.75, 0.25, 1, duration: 1.0)) { sweep = 1 }
            withAnimation(.easeOut(duration: 0.25).delay(0.85)) { knobShown = true }
        }
    }
}

/// Центр циферблата. Каждую секунду обновляется только этот текст.
struct DialCenter: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    let inspection: DialInspection?
    let scale: CGFloat

    var body: some View {
        Group {
            if let inspection {
                inspected(inspection)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    summary(date: context.date)
                }
            }
        }
        .multilineTextAlignment(.center)
        .allowsHitTesting(false)
    }

    private func summary(date: Date) -> some View {
        let metrics = store.liveMetrics(at: date).day
        let observed = metrics.online + metrics.offline
        return VStack(spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(Palette.on).frame(width: 8, height: 8)
                Text("в сети")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.ink2)
            Text(Fmt.duration(metrics.online))
                .font(.rounded(38 * scale))
                .tracking(-1)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(observed > 0 ? Fmt.percent(metrics.online / observed * 100) + " времени" : "статус не подтверждён")
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .lineLimit(2)
        }
    }

    private func inspected(_ inspection: DialInspection) -> some View {
        let tz = state.tz
        let row = inspection.rowStart.flatMap { start in state.rows.first(where: { $0.start == start }) }
        var range = Fmt.time(inspection.t, tz: tz)
        var value = "Нет данных"
        var caption = "наблюдение не велось"
        var dot: String?
        if inspection.future {
            value = "Впереди"
            caption = "ещё не наступило"
        } else if let row {
            let live = row.isOngoing && state.isToday
            range = Fmt.time(row.start, tz: tz) + " – " + (live ? "сейчас" : Fmt.time(row.end, tz: tz))
            let duration = live ? max(0, store.serverNow() - row.start) : row.duration
            value = Fmt.duration(duration, detailed: duration < 3600)
            caption = row.state == "unknown" ? (row.reason ?? "Нет данных") : Labels.state(row.state)
            dot = row.state
        }
        return VStack(spacing: 6) {
            Text(range)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
            Text(value)
                .font(.rounded(34 * scale))
                .tracking(-0.8)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                if let dot {
                    StatusDot(state: dot, size: 8, pulses: false)
                }
                Text(caption)
                    .lineLimit(2)
            }
            .font(.system(size: 13, weight: dot == nil ? .regular : .medium))
            .foregroundStyle(dot == nil ? Palette.ink2 : Palette.ink)
        }
    }
}
