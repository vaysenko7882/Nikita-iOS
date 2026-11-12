import SwiftUI

/// Живая карточка: кто, в сети ли сейчас и сколько.
struct StatusCard: View {
    @EnvironmentObject private var store: PresenceStore
    let state: PresenceState
    let date: Date

    var body: some View {
        let live = store.liveState(at: date)
        let connected = store.isConnected(at: date)
        let profile = state.profile
        let avatarURL: URL? = (profile?.hasAvatar ?? false) ? store.api.avatarURL(version: profile?.avatarVersion) : nil

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                AvatarView(profile: profile, url: avatarURL)
                    .frame(width: 60, height: 60)
                    .overlay(AvatarRing(state: live).padding(-5))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(profile?.name ?? "Мой аккаунт")
                            .font(.rounded(21))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(2)
                        Text("мой аккаунт")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Palette.page, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .fixedSize()
                    }
                    HStack(spacing: 10) {
                        Text(profile?.handle ?? "Без username")
                        Text("ID " + (profile?.id ?? "—"))
                            .monospacedDigit()
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }

            HStack(spacing: 12) {
                StatusDot(state: live, size: 14)
                Text(connected ? Labels.state(live) : "Нет связи с сайтом")
                    .font(.rounded(38))
                    .tracking(-0.8)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.top, 26)

            Text(store.statusLine(at: date))
                .font(.system(size: 17))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if let note = store.pauseNote(at: date) {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Rectangle()
                .fill(Palette.hair)
                .frame(height: 1)
                .padding(.top, 22)

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Наблюдаем с")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.ink2)
                    Text(trackingText)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Text(confirmedText)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.top, 16)
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 20, trailing: 22))
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(live == "online" ? Palette.onSoft : Palette.panel)
        )
        .animation(.easeInOut(duration: 0.5), value: live)
        .accessibilityElement(children: .combine)
    }

    private var trackingText: String {
        guard let started = state.trackingStarted else { return "—" }
        return Fmt.dayText(Fmt.isoDay(started, tz: state.tz), "d MMM") + ", " + Fmt.time(started, tz: state.tz)
    }

    private var confirmedText: String {
        guard let observed = state.current.lastObserved else { return "Ожидаем Telegram" }
        return "Подтверждено в " + Fmt.time(observed, tz: state.tz, seconds: true)
    }
}
