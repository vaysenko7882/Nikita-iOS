import SwiftUI

/// Живая карточка: кто, в сети ли сейчас и сколько. Тикает только она сама.
struct StatusCard: View {
    @Environment(PresenceStore.self) private var store
    let state: PresenceState
    var onExport: () -> Void
    var onSite: () -> Void
    var onDiagnostics: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            card(date: context.date)
        }
        .overlay(alignment: .topTrailing) {
            menu
                .padding(.top, 20)
                .padding(.trailing, 18)
        }
    }

    private func card(date: Date) -> some View {
        let live = store.liveState(at: date)
        let profile = state.profile
        let avatarURL: URL? = (profile?.hasAvatar ?? false) ? store.api.avatarURL(version: profile?.avatarVersion) : nil

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                AvatarView(profile: profile, url: avatarURL)
                    .frame(width: 52, height: 52)
                    .overlay(AvatarRing(state: live).padding(-5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile?.name ?? "Мой аккаунт")
                        .font(.rounded(19))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(profile?.handle ?? "Без username")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 44)
            }

            HStack(spacing: 12) {
                StatusDot(state: live, size: 14)
                Text(store.headline(at: date))
                    .font(.rounded(40))
                    .tracking(-0.8)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.top, 28)

            Text(store.statusLine(at: date))
                .font(.system(size: 17))
                .monospacedDigit()
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            if let note = store.pauseNote(at: date) {
                Text(note)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(live == "online" ? Palette.onSoft : Palette.panel)
        )
        .animation(.easeInOut(duration: 0.5), value: live)
        .accessibilityElement(children: .combine)
    }

    private var menu: some View {
        Menu {
            Button("Экспорт CSV", systemImage: "square.and.arrow.down", action: onExport)
            Button("Открыть сайт", systemImage: "safari", action: onSite)
            Button("Связь с Telegram", systemImage: "antenna.radiowaves.left.and.right", action: onDiagnostics)
            Button("Обновить", systemImage: "arrow.clockwise") {
                Task { await store.refresh(force: true) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .frame(width: 36, height: 36)
                .background(Palette.page.opacity(0.7), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(Text("Меню"))
    }
}
