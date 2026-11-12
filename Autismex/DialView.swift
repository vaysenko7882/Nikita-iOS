import SwiftUI

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

    var animatableData: Double {
        get { sweep }
        set { sweep = newValue }
    }

    var body: some View {
        Canvas { context, size in
            DialPainter.paint(&context, size: size, segments: segments, dayStart: dayStart, dayEnd: dayEnd, sweep: sweep)
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

/// Циферблат суток. Удержание и ведение пальцем — разбор времени с тактильным щелчком
/// на каждом отрезке. Короткое касание кольца — отрезок под пальцем.
struct DialView: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    let now: Double
    let liveState: String
    let onlineSeconds: Double
    let note: String
    @Binding var scrubbing: Bool
    var onLearned: () -> Void = {}

    @State private var inspection: DialInspection?
    @State private var releaseTask: Task<Void, Never>?
    @State private var sweep: Double = 0
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dayStart: Double { state.dayStart }
    private var dayEnd: Double { state.dayEnd }

    private var segments: [DialSegment] {
        state.rows.map { row in
            DialSegment(state: row.state, start: row.start, end: store.liveEnd(row))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                DialCanvas(sweep: sweep, segments: segments, dayStart: dayStart, dayEnd: dayEnd)
                if state.isToday && sweep > 0.99 {
                    NowKnob(state: liveState)
                        .frame(width: 24 * side / 340, height: 24 * side / 340)
                        .position(point(for: min(now, dayEnd), side: side))
                }
                if let inspection {
                    needle(for: inspection.t, side: side)
                }
                center(side: side)
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(scrubGesture(side: side))
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    tap(at: value.location, side: side)
                }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.selection, trigger: inspection?.rowStart ?? -1)
        .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, isOn in isOn }
        .onChange(of: pressing) { _, isPressing in
            scrubbing = isPressing
            if !isPressing {
                onLearned()
                release(after: 1.8)
            }
        }
        .onAppear { runSweep() }
        .onChange(of: state.date) { _, _ in
            inspection = nil
            runSweep()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Циферблат дня. В сети " + Fmt.duration(onlineSeconds) + ". " + note))
    }

    // MARK: Рисование

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

    private func center(side: CGFloat) -> some View {
        let u = side / 340
        return Group {
            if let inspection {
                inspectionContent(inspection, u: u)
            } else {
                mainContent(u: u)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: side * 0.58)
        .allowsHitTesting(false)
    }

    private func mainContent(u: CGFloat) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(Palette.on).frame(width: 8, height: 8)
                Text("в сети")
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Palette.ink2)
            Text(Fmt.duration(onlineSeconds))
                .font(.rounded(38 * u))
                .tracking(-1)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(note)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink2)
                .lineLimit(2)
        }
    }

    private func inspectionContent(_ inspection: DialInspection, u: CGFloat) -> some View {
        let tz = state.tz
        let row = inspection.rowStart.flatMap { start in state.rows.first(where: { $0.start == start }) }
        var range = Fmt.time(inspection.t, tz: tz)
        var value = "Нет данных"
        var caption = "наблюдение не велось"
        var dot: String?
        if inspection.future {
            value = "Впереди"
            caption = "это время ещё не наступило"
        } else if let row {
            let live = row.isOngoing && state.isToday
            range = Fmt.time(row.start, tz: tz) + " – " + (live ? "сейчас" : Fmt.time(row.end, tz: tz))
            let duration = live ? max(0, now - row.start) : row.duration
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
                .font(.rounded(34 * u))
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

    // MARK: Жесты

    /// Удержание 0,2 с, затем ведение пальцем. @GestureState сбрасывается сам,
    /// даже если жест отменила система, поэтому прокрутка не «залипает».
    private func scrubGesture(side: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .updating($pressing) { value, isPressing, _ in
                if case .second(true, _) = value { isPressing = true }
            }
            .onChanged { value in
                if case .second(true, let drag?) = value {
                    inspect(at: drag.location, side: side, requireRing: false)
                }
            }
    }

    private func tap(at location: CGPoint, side: CGFloat) {
        guard !pressing else { return }
        if inspect(at: location, side: side, requireRing: true) {
            release(after: 2.6)
        } else if inspection != nil {
            release(after: 0)
        }
    }

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
        let limit = state.isToday ? now : dayEnd
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
            return
        }
        sweep = 0
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.3, 0.75, 0.25, 1, duration: 1.1)) { sweep = 1 }
        }
    }
}
