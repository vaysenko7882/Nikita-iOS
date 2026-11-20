import SwiftUI

/// Адрес сервера: при первом запуске (если он не вшит в приложение) и из ссылки slou://settings
struct SetupView: View {
    let first: Bool
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first {
                HStack {
                    Spacer()
                    GlassIconButton(systemName: "xmark", size: 40) { dismiss() }
                        .accessibilityLabel("Закрыть")
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 24)
            Text("слоу")
                .font(Theme.display(64, relativeTo: .largeTitle))
                .foregroundStyle(Theme.ink)
            Text("Адрес твоего сервера — тот, что показал установщик. Можно просто домен или IP.")
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.dim)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
            TextField("slows.best", text: $text)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($focused)
                .onSubmit(save)
                .padding(.horizontal, 20)
                .frame(height: 58)
                .slouGlass(in: Capsule(), interactive: true)
                .padding(.top, 28)
            if let error {
                Text(error)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.danger)
                    .padding(.top, 10)
                    .padding(.horizontal, 6)
            }
            if !first {
                Button {
                    model.requestsDemoRoom = true
                } label: {
                    HStack(spacing: 12) {
                        CrownGlyph(size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Демо-комната").font(.system(size: 17, weight: .bold, design: .rounded))
                            Text("10 игр с ботом без интернета")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.5))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .slouGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.demo")
                .padding(.top, 22)
            }
            Spacer(minLength: 24)
            Button("Подключиться", action: save)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmed.isEmpty)
                .opacity(text.trimmed.isEmpty ? 0.5 : 1)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(AmbientBackground())
        .onAppear {
            text = model.server
            if first { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
        }
    }

    private func save() {
        guard let url = AppModel.normalize(text) else {
            error = "Не похоже на адрес. Пример: slows.best или 203.0.113.7"
            Haptics.shared.play("error")
            return
        }
        error = nil
        Haptics.shared.play("success")
        model.server = url.absoluteString
        if !first { dismiss() }
    }
}

/// Сервер не открылся
struct FailureView: View {
    let message: String
    let retry: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse)
            Text("Не открылось")
                .font(Theme.display(34, relativeTo: .title))
                .foregroundStyle(Theme.ink)
                .padding(.top, 20)
            Text(message)
                .font(.system(size: 16, design: .rounded))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Spacer()
            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    Button("Ещё раз") {
                        Haptics.shared.play("light")
                        retry()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Сменить сервер", action: settings)
                        .buttonStyle(GlassButtonStyle())
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background(AmbientBackground())
    }
}
