import SwiftUI

/// Отрезок для циферблата суток.
struct DialSegment: Sendable {
    var state: String
    var start: Double
    var end: Double
}

/// Геометрия циферблата: полночь сверху, время идёт по часовой стрелке.
/// Размеры заданы для квадрата 340×340 и масштабируются коэффициентом u.
enum Dial {
    static let tau = Double.pi * 2

    static func angle(_ t: Double, start: Double, end: Double) -> Double {
        let span = max(1, end - start)
        return (t - start) / span * tau - Double.pi / 2
    }

    static func point(_ angle: Double, _ radius: CGFloat, _ center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
    }

    private static func appendArc(_ path: inout Path, from a0: Double, to a1: Double, radius: CGFloat, center: CGPoint) {
        let steps = max(1, Int((abs(a1 - a0) / 0.015).rounded(.up)))
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Double(i) / Double(steps)
            path.addLine(to: point(a, radius, center))
        }
    }

    static func arc(_ a0: Double, _ a1: Double, radius: CGFloat, center: CGPoint) -> Path {
        var path = Path()
        path.move(to: point(a0, radius, center))
        appendArc(&path, from: a0, to: a1, radius: radius, center: center)
        return path
    }

    /// Закруглённый сектор кольца — так рисуется сеанс онлайн.
    static func sector(_ a0: Double, _ a1Raw: Double, inner ri: CGFloat, outer ro: CGFloat, center: CGPoint, corner: CGFloat) -> Path {
        let width = min(a1Raw - a0, tau - 0.001)
        let a1 = a0 + width
        var path = Path()
        let rc = max(0, min(corner, CGFloat(width) * ri / 2 - 0.05))
        if rc < 0.6 {
            path.move(to: point(a0, ro, center))
            appendArc(&path, from: a0, to: a1, radius: ro, center: center)
            path.addLine(to: point(a1, ri, center))
            appendArc(&path, from: a1, to: a0, radius: ri, center: center)
            path.closeSubpath()
            return path
        }
        let dO = Double(rc / ro)
        let dI = Double(rc / ri)
        path.move(to: point(a0 + dO, ro, center))
        appendArc(&path, from: a0 + dO, to: a1 - dO, radius: ro, center: center)
        path.addQuadCurve(to: point(a1, ro - rc, center), control: point(a1, ro, center))
        path.addLine(to: point(a1, ri + rc, center))
        path.addQuadCurve(to: point(a1 - dI, ri, center), control: point(a1, ri, center))
        appendArc(&path, from: a1 - dI, to: a0 + dI, radius: ri, center: center)
        path.addQuadCurve(to: point(a0, ri + rc, center), control: point(a0, ri, center))
        path.addLine(to: point(a0, ro - rc, center))
        path.addQuadCurve(to: point(a0 + dO, ro, center), control: point(a0, ro, center))
        path.closeSubpath()
        return path
    }
}

/// Рисует циферблат в Canvas. Используется и приложением, и виджетами.
enum DialPainter {
    static func paint(
        _ context: inout GraphicsContext,
        size: CGSize,
        segments: [DialSegment],
        dayStart: Double,
        dayEnd: Double,
        sweep: Double = 1,
        showLabels: Bool = true,
        showTicks: Bool = true,
        habit: [Double]? = nil,
        knobAt: Double? = nil,
        knobState: String = "unknown"
    ) {
        let side = min(size.width, size.height)
        let u: CGFloat = side / 340
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 128 * u

        // Ещё не наступившее время — пунктир.
        let track = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.stroke(track, with: .color(Palette.ink3.opacity(0.55)),
                       style: StrokeStyle(lineWidth: max(1, 2.6 * u), lineCap: .round, dash: [0.01, max(3, 6.7 * u)]))

        if let habit, habit.count == 24 {
            // Привычный ритм недели: точка в середине каждого часа, чем чаще в сети — тем крупнее и зеленее.
            for hour in 0..<24 {
                let a = (Double(hour) + 0.5) / 24 * Dial.tau - Double.pi / 2
                let p = Dial.point(a, 103 * u, center)
                let share = max(0, min(1, habit[hour]))
                if share > 0.03 {
                    let r: CGFloat = (1.6 + 2.8 * CGFloat(share.squareRoot())) * u
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Palette.on.opacity(0.35 + 0.65 * share)))
                } else {
                    let r: CGFloat = 1.1 * u
                    context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(Palette.ink3.opacity(0.5)))
                }
            }
        } else if showTicks {
            for hour in 0..<24 {
                let a = Double(hour) / 24 * Dial.tau - Double.pi / 2
                let p = Dial.point(a, 104 * u, center)
                let r: CGFloat = (hour % 6 == 0 ? 2.0 : 1.15) * u
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(Palette.ink3.opacity(hour % 6 == 0 ? 1 : 0.5)))
            }
        }

        if showLabels {
            for hour in [0, 6, 12, 18] {
                let a = Double(hour) / 24 * Dial.tau - Double.pi / 2
                let p = Dial.point(a, 156 * u, center)
                let label = Text(verbatim: Fmt.two(hour))
                    .font(.system(size: 11 * u, weight: .medium))
                    .foregroundColor(Palette.ink2)
                context.draw(label, at: p, anchor: .center)
            }
        }

        let limit = -Double.pi / 2 + max(0, min(1, sweep)) * Dial.tau

        for segment in segments where segment.state != "online" {
            let a0 = Dial.angle(segment.start, start: dayStart, end: dayEnd)
            if a0 >= limit { continue }
            let a1 = min(limit, max(Dial.angle(segment.end, start: dayStart, end: dayEnd), a0 + 0.002))
            let path = Dial.arc(a0, a1, radius: radius, center: center)
            if segment.state == "offline" {
                context.stroke(path, with: .color(Palette.off), lineWidth: 14 * u)
            } else {
                context.stroke(path, with: .color(Palette.future), lineWidth: 14 * u)
                context.stroke(path, with: .color(Palette.ink3.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 14 * u, dash: [max(1, 1.4 * u), max(2, 3.2 * u)]))
            }
        }

        for segment in segments where segment.state == "online" {
            let a0 = Dial.angle(segment.start, start: dayStart, end: dayEnd)
            if a0 >= limit { continue }
            let minimum = Double(3 / 128.0)
            let a1 = min(limit, max(Dial.angle(segment.end, start: dayStart, end: dayEnd), a0 + minimum))
            let sector = Dial.sector(a0, a1, inner: 116 * u, outer: 140 * u, center: center, corner: 3.5 * u)
            context.fill(sector, with: .color(Palette.on))
        }

        if let knobAt {
            let p = Dial.point(Dial.angle(min(knobAt, dayEnd), start: dayStart, end: dayEnd), radius, center)
            let knob: CGFloat = max(5, 12 * u)
            let core: CGFloat = max(2.5, 6 * u)
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.28), radius: max(1, 1.6 * u), x: 0, y: max(0.5, u)))
                layer.fill(Path(ellipseIn: CGRect(x: p.x - knob, y: p.y - knob, width: knob * 2, height: knob * 2)), with: .color(.white))
            }
            let coreRect = CGRect(x: p.x - core, y: p.y - core, width: core * 2, height: core * 2)
            if knobState == "online" || knobState == "offline" {
                context.fill(Path(ellipseIn: coreRect), with: .color(Palette.state(knobState)))
            } else {
                context.stroke(Path(ellipseIn: coreRect), with: .color(Palette.ink3), lineWidth: max(1, 1.6 * u))
            }
        }
    }
}
