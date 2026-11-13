import SwiftUI

/// Плавающая панель дня у большого пальца. Смахивание по ней вбок листает дни.
/// Подпись меняется сразу при нажатии, не дожидаясь ответа сервера, поэтому
/// стрелку можно нажать несколько раз подряд.
struct DateBar: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    var onPickDate: () -> Void

    var body: some View {
        let shown = store.pendingDate ?? state.date
        let isToday = shown == state.today

        HStack(spacing: 4) {
            barButton("chevron.left", label: "Предыдущий день") { store.move(by: -1) }
            Button(action: onPickDate) {
                HStack(spacing: 6) {
                    Text(Fmt.shortDay(shown, today: state.today))
                        .font(.rounded(17))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.ink2)
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Выбрать дату, сейчас " + Fmt.dayText(shown, "d MMMM")))
            barButton("chevron.right", label: "Следующий день") { store.move(by: 1) }
                .disabled(isToday)
                .opacity(isToday ? 0.25 : 1)
            if !isToday {
                Button {
                    store.pick(state.today)
                } label: {
                    Text("Сегодня")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.page)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Palette.ink, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(7)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 14, x: 0, y: 6)
        }
        .overlay(Capsule().strokeBorder(Palette.hair, lineWidth: 0.5))
        .frame(maxWidth: 440)
        .animation(.snappy, value: isToday)
        .sensoryFeedback(.selection, trigger: shown)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width > 60 {
                        store.move(by: -1)
                    } else if value.translation.width < -60 && !isToday {
                        store.move(by: 1)
                    }
                }
        )
    }

    private func barButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

struct DatePickerSheet: View {
    let state: PresenceState
    let onPick: (String) -> Void
    @State private var date: Date
    @Environment(\.dismiss) private var dismiss

    init(state: PresenceState, onPick: @escaping (String) -> Void) {
        self.state = state
        self.onPick = onPick
        _date = State(initialValue: Fmt.localDate(state.date))
    }

    private var range: ClosedRange<Date> {
        let upper = Fmt.localDate(state.today)
        let lower = state.trackingStarted.map { Fmt.localDate(Fmt.isoDay($0, tz: state.tz)) } ?? upper.addingTimeInterval(-365 * 86_400)
        return min(lower, upper)...upper
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                DatePicker("Дата", selection: $date, in: range, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Palette.on)
                    .padding(.horizontal)
                Spacer(minLength: 0)
            }
            .navigationTitle("Выбор дня")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Открыть") { onPick(Fmt.isoLocal(date)) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
