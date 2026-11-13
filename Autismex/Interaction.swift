import SwiftUI
import Observation

/// Связки между частями экрана: «показать отрезок на циферблате», «прокрутить к дню»,
/// «карточка статуса ушла за верх». Вынесено отдельно, чтобы такие мелочи
/// не перерисовывали весь экран.
@MainActor
@Observable
final class Interaction {
    struct ScrollRequest: Equatable {
        var target: String
        var token: Int
    }

    /// Карточка статуса прокручена за верх экрана.
    var pastHero = false
    var scrollRequest = ScrollRequest(target: "top", token: 0)
    var focusStart: Double? = nil
    var focusToken = 0

    func scroll(to target: String) {
        scrollRequest = ScrollRequest(target: target, token: scrollRequest.token + 1)
    }

    /// Показать отрезок на циферблате: прокрутить к нему и навести стрелку.
    func focus(_ start: Double) {
        focusStart = start
        focusToken += 1
        scroll(to: "dial")
    }
}

/// Следит, ушла ли карточка статуса за верх экрана. Срабатывает только в момент
/// пересечения порога, а не на каждый кадр прокрутки. До iOS 18 просто отключено.
struct HeroTracker: ViewModifier {
    let interaction: Interaction

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 180
            } action: { _, isPast in
                interaction.pastHero = isPast
            }
        } else {
            content
        }
    }
}

/// Маленькая плашка статуса вверху, когда карточка статуса не видна.
/// Нажатие возвращает к началу.
struct MiniStatus: View {
    @Environment(PresenceStore.self) private var store
    @Environment(Interaction.self) private var interaction

    var body: some View {
        ZStack {
            if interaction.pastHero {
                Button {
                    interaction.scroll(to: "top")
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        label(date: context.date)
                    }
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: interaction.pastHero)
    }

    private func label(date: Date) -> some View {
        let live = store.liveState(at: date)
        return HStack(spacing: 7) {
            StatusDot(state: live, size: 9, pulses: false)
            Text(store.headline(at: date))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if let duration = store.statusDuration(at: date) {
                Text(duration)
                    .font(.system(size: 14))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hair, lineWidth: 0.5))
        .contentShape(Capsule())
    }
}
