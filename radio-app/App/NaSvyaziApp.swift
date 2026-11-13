import SwiftUI
import Combine
import UIKit
import Security

@main
struct NaSvyaziApp: App {
    @StateObject private var model = RadioModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RadioHome(model: model)
                .preferredColorScheme(.dark)
                .onOpenURL { model.acceptInvite($0) }
                .onChange(of: scenePhase) { phase in
                    if phase != .active && !model.system.joined { model.releaseTalk() }
                }
        }
    }
}

@MainActor
final class RadioModel: ObservableObject {
    let link = RadioLink()
    let audio = RadioAudio()
    let system = SystemPTT()
    @Published var name = UserDefaults.standard.string(forKey: "displayName") ?? "Мой iPhone"
    @Published var room = UserDefaults.standard.string(forKey: "roomCode") ?? RadioModel.makeCode()
    @Published var server = UserDefaults.standard.string(forKey: "relayURL") ?? ""
    @Published var internet = UserDefaults.standard.bool(forKey: "internetMode")
    @Published var settings = false
    @Published var wantsTalk = false
    @Published var targetID: String?
    @Published var remoteName = ""
    @Published var message: String?
    @Published var showCode = false
    private var cancellables = Set<AnyCancellable>()
    private var waitingAudio: [Data] = []

    var joined: Bool { link.isConnected }
    var activeName: String { wantsTalk ? "Вы в эфире" : (remoteName.isEmpty ? "Можно говорить" : "\(remoteName) говорит") }
    var invite: URL { var c = URLComponents(); c.scheme = "nasvyazi"; c.host = "join"; c.queryItems = [URLQueryItem(name: "room", value: room)]; return c.url! }
    var displayCode: String { String(room.prefix(4)) + " · " + String(room.dropFirst(4).prefix(4)) + " · " + String(room.dropFirst(8)) }

    init() {
        for publisher in [link.objectWillChange.eraseToAnyPublisher(), audio.objectWillChange.eraseToAnyPublisher(), system.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        audio.onPacket = { [weak self] packet in self?.link.sendAudio(packet) }
        link.onAudio = { [weak self] data in
            guard let self else { return }
            if self.system.joined && !self.system.audioActive {
                self.waitingAudio.append(data)
                if self.waitingAudio.count > 20 { self.waitingAudio.removeFirst() }
            } else { self.audio.receive(data) }
        }
        link.onRemoteTalk = { [weak self] name, active in
            guard let self else { return }
            self.remoteName = active ? name : ""
            if self.system.joined { self.system.setRemoteSpeaker(name: active ? name : nil) }
            else if active { self.audio.prepareSession() }
        }
        system.onBegin = { [weak self] in
            guard let self, self.link.isConnected else { return }
            self.wantsTalk = true
            self.link.setTalking(true, targetID: self.targetID)
            if self.system.audioActive { self.audio.startTalking() }
        }
        system.onEnd = { [weak self] in self?.finishAudio() }
        system.onActivated = { [weak self] in
            guard let self else { return }
            self.audio.prepareSession(activate: false)
            for data in self.waitingAudio { self.audio.receive(data) }
            self.waitingAudio.removeAll()
            if self.wantsTalk { self.audio.startTalking() }
        }
        system.onDeactivated = { [weak self] in self?.audio.stopAll() }
        system.onIncomingSpeaker = { [weak self] name in
            guard let self else { return }
            self.remoteName = name
            if !self.link.isConnected && UserDefaults.standard.bool(forKey: "wasConnected") {
                self.link.connect(room: self.room, name: self.name, serverURL: self.internet ? self.server : "")
            } else { self.link.resumeConnection() }
        }
        link.onTalkDenied = { [weak self] in self?.releaseTalk() }
        system.onPushToken = { [weak self] token in
            guard let self else { return }
            self.link.updatePushToken(token, channelID: SystemPTT.roomUUID(for: self.room))
        }
        #if UI_SNAPSHOT
        name = "Никита"; room = "SVYAZI123456"; remoteName = ""
        #else
        system.configure()
        #endif
    }

    static func makeCode() -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess { return UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased() }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
    func connect() {
        let clean = room.filter { !$0.isWhitespace && $0 != "·" }.uppercased()
        guard clean.count >= 12 && clean.count <= 64 else { message = "Введите общий код длиной от 12 символов. У друга должен быть такой же код."; return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { message = "Введите своё имя."; return }
        if internet && !server.lowercased().hasPrefix("wss://") { message = "Для интернета укажите адрес своего сервера вида wss://example.com/ws."; settings = true; return }
        room = clean; name = String(cleanName.prefix(24))
        UserDefaults.standard.set(name, forKey: "displayName")
        UserDefaults.standard.set(room, forKey: "roomCode")
        UserDefaults.standard.set(server, forKey: "relayURL")
        UserDefaults.standard.set(internet, forKey: "internetMode")
        UserDefaults.standard.set(true, forKey: "wasConnected")
        link.connect(room: room, name: name, serverURL: internet ? server.trimmingCharacters(in: .whitespacesAndNewlines) : "")
        system.join(roomCode: room, title: "На связи · \(room.suffix(4))")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    func disconnect() { UserDefaults.standard.set(false, forKey: "wasConnected"); releaseTalk(); system.leave(); link.disconnect(); audio.stopAll(); waitingAudio.removeAll(); remoteName = "" }
    func holdTalk(_ target: String?) {
        guard joined, !wantsTalk else { return }
        guard remoteName.isEmpty else { message = "Сейчас говорит \(remoteName). Дождитесь конца передачи."; return }
        targetID = target; wantsTalk = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if system.joined { system.begin() }
        else { audio.prepareSession(); audio.startTalking(); link.setTalking(true, targetID: target) }
    }
    func releaseTalk() { if system.joined { system.end() }; finishAudio() }
    private func finishAudio() {
        let wasTalking = wantsTalk
        wantsTalk = false; audio.stopTalking()
        if wasTalking { link.setTalking(false, targetID: targetID) }
        targetID = nil
    }
    func acceptInvite(_ url: URL) {
        guard url.scheme == "nasvyazi", let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = c.queryItems?.first(where: { $0.name == "room" })?.value else { return }
        if joined { disconnect() }
        room = code; message = "Код заполнен. Нажмите «Включить рацию», чтобы подключиться." 
    }
}

private let ink = Color(red: 0.055, green: 0.065, blue: 0.105)
private let violet = Color(red: 0.56, green: 0.42, blue: 1)
private let mint = Color(red: 0.65, green: 0.98, blue: 0.72)

struct RadioHome: View {
    @ObservedObject var model: RadioModel
    @State private var help = false
    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            RadialGradient(colors: [violet.opacity(0.16), .clear], center: .topTrailing, startRadius: 0, endRadius: 450).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if model.joined { connected } else { welcome }
                    codeCard
                    if !model.joined { joinControls }
                    footer
                }.padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $model.settings) { settings }
        .sheet(isPresented: $help) { helpSheet }
        .alert("На связи", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("Понятно", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
        .onChange(of: model.audio.error) { value in if let value { model.message = value; model.releaseTalk() } }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2.bold()).foregroundColor(mint)
                Text("на связи").font(.system(size: 27, weight: .heavy, design: .rounded))
            }
            Spacer()
            Button { model.settings = true } label: { Image(systemName: "slider.horizontal.3").font(.title3).frame(width: 42, height: 42).background(.white.opacity(0.07), in: Circle()) }
                .accessibilityLabel("Настройки")
        }.foregroundColor(.white)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 6) { Circle().fill(mint).frame(width: 6, height: 6); Text("ГОЛОС БЕЗ ЗВОНКА").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2) }.foregroundColor(mint)
            Text("Нажми.\nСкажи.\nТы рядом.").font(.system(size: 48, weight: .heavy, design: .rounded)).tracking(-2).lineSpacing(-2)
            Text("Зажми аватар друга — он услышит тебя, пока ты говоришь.").font(.system(size: 16)).foregroundColor(.white.opacity(0.6)).lineSpacing(5)
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(violet.opacity(0.2), lineWidth: 1).frame(width: 100, height: 100)
                    Circle().fill(LinearGradient(colors: [violet, Color(red: 0.34, green: 0.28, blue: 0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 76, height: 76)
                    Image(systemName: "hand.tap.fill").font(.system(size: 30)).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Живой голос").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Передаётся сразу.\nОтпустил — закончил.").font(.system(size: 13)).foregroundColor(.white.opacity(0.5)).lineSpacing(3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
        }.foregroundColor(.white)
    }

    private var connected: some View {
        VStack(spacing: 22) {
            HStack(spacing: 7) {
                Circle().fill(model.wantsTalk ? violet : mint).frame(width: 7, height: 7)
                Text(model.activeName.uppercased()).font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(1.6)
                Spacer()
                Text(model.internet ? "ИНТЕРНЕТ" : "РЯДОМ").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.4))
            }.foregroundColor(mint)
            if model.link.peers.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 38)).foregroundColor(violet)
                    Text("Ждём твоих людей").font(.system(size: 23, weight: .bold, design: .rounded))
                    Text("Пусть друг откроет приложение,\nвведёт ваш код и включит рацию.").font(.system(size: 14)).foregroundColor(.white.opacity(0.5)).multilineTextAlignment(.center).lineSpacing(4)
                }.frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 24) {
                    ForEach(model.link.peers) { peer in
                        VStack(spacing: 12) {
                            avatar(peer.name, active: model.wantsTalk && model.targetID == peer.id, size: 110)
                                .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 100, pressing: { down in if down { model.holdTalk(peer.id) } else { model.releaseTalk() } }, perform: {})
                                .accessibilityLabel("Говорить с \(peer.name)")
                                .accessibilityHint("Удерживайте, чтобы передавать голос")
                            Text(peer.name).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1)
                            Text("ЗАЖМИ И ГОВОРИ").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(1).foregroundColor(.white.opacity(0.35))
                        }.padding(.vertical, 8)
                    }
                }.padding(.vertical, 5)
            }
            if !model.link.peers.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: model.wantsTalk && model.targetID == nil ? "waveform" : "mic.fill").font(.title2)
                    Text(model.wantsTalk && model.targetID == nil ? "Ты в эфире…" : "Говорить всем").font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Image(systemName: "hand.point.up.left.fill").font(.title3)
                }.foregroundColor(ink).padding(20).background(mint, in: RoundedRectangle(cornerRadius: 24))
                    .scaleEffect(model.wantsTalk && model.targetID == nil ? 0.97 : 1)
                    .animation(.easeOut(duration: 0.15), value: model.wantsTalk)
                    .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 120, pressing: { down in if down { model.holdTalk(nil) } else { model.releaseTalk() } }, perform: {})
            }
            Text(model.link.status).font(.system(size: 12)).foregroundColor(.white.opacity(0.4)).multilineTextAlignment(.center)
            if let error = model.link.error { Text(error).font(.system(size: 12)).foregroundColor(.orange).multilineTextAlignment(.center) }
            Button("Выключить рацию") { model.disconnect() }.font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.45))
        }.foregroundColor(.white)
    }

    private func avatar(_ name: String, active: Bool, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(active ? mint : violet.opacity(0.22), lineWidth: active ? 4 : 1).frame(width: size + 16, height: size + 16)
            Circle().fill(LinearGradient(colors: [violet, Color(red: 0.27, green: 0.3, blue: 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: size, height: size)
            if active { Image(systemName: "waveform").font(.system(size: 38, weight: .medium)).foregroundColor(mint) }
            else { Text(String(name.prefix(1)).uppercased()).font(.system(size: 42, weight: .bold, design: .rounded)).foregroundColor(.white) }
        }.frame(width: size + 20, height: size + 20).contentShape(Circle())
    }

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("ВАШ ОБЩИЙ КОД").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1.7).foregroundColor(.white.opacity(0.4)); Spacer(); Image(systemName: "lock.fill").font(.caption).foregroundColor(.white.opacity(0.3)) }
            if model.joined {
                HStack {
                    Text(model.showCode ? model.displayCode : "•••• · •••• · ••••").font(.system(size: 19, weight: .bold, design: .monospaced)).foregroundColor(.white)
                    Spacer()
                    Button { model.showCode.toggle() } label: { Image(systemName: model.showCode ? "eye.slash" : "eye").foregroundColor(.white.opacity(0.6)) }
                }
            } else {
                TextField("Код от друга", text: $model.room).font(.system(size: 20, weight: .bold, design: .monospaced)).textInputAutocapitalization(.characters).autocorrectionDisabled().foregroundColor(.white)
            }
            HStack {
                if !model.joined { Button { model.room = RadioModel.makeCode() } label: { Label("Новый код", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .medium)) }.foregroundColor(.white.opacity(0.5)) }
                Spacer()
                ShareLink(item: model.invite) { Label("Пригласить", systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .semibold)).foregroundColor(mint) }
            }
        }.padding(20).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.07)))
    }

    private var joinControls: some View {
        VStack(spacing: 16) {
            HStack { Image(systemName: "person.fill").foregroundColor(.white.opacity(0.3)); TextField("Твоё имя", text: $model.name).font(.system(size: 16)).foregroundColor(.white).textInputAutocapitalization(.words).autocorrectionDisabled() }.padding(17).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
            Picker("Способ связи", selection: $model.internet) { Text("Рядом").tag(false); Text("Интернет").tag(true) }.pickerStyle(.segmented)
            if model.internet { Button("Настроить сервер интернета") { model.settings = true }.font(.system(size: 12)).foregroundColor(violet) }
            Button { model.connect() } label: { HStack { Text("Включить рацию"); Spacer(); Image(systemName: "arrow.up.right") }.font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(ink).padding(20).background(mint, in: RoundedRectangle(cornerRadius: 24)) }
        }
    }

    private var footer: some View {
        Button { help = true } label: {
            HStack(alignment: .top, spacing: 10) { Image(systemName: "info.circle"); Text(model.internet ? "Интернет работает через ваш сервер. Приём на заблокированном экране требует настройки системной рации." : "Режим «Рядом»: включите Wi-Fi и Bluetooth на обоих iPhone. Приложение ищет только участников с вашим кодом.").lineSpacing(3) }.font(.system(size: 11)).foregroundColor(.white.opacity(0.34)).multilineTextAlignment(.leading)
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("Твой профиль") { TextField("Имя", text: $model.name).disabled(model.joined) }
                Section { TextField("wss://example.com/ws", text: $model.server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).disabled(model.joined) } header: { Text("Сервер интернета") } footer: { Text("Для связи через интернет нужен собственный сервер ретрансляции. В режиме «Рядом» адрес не требуется.") }
                Section("Системная рация") {
                    LabeledContent("Состояние", value: model.system.joined ? "Канал включён" : (model.system.available ? "Готова" : "Обычный режим"))
                    Text("Автоматический приём при заблокированном экране требует разрешения Push to Talk в подписи приложения и APNs на сервере. Без них доступна связь при открытом приложении.").font(.caption).foregroundColor(.secondary)
                    if let error = model.system.error { Text(error).font(.caption).foregroundColor(.secondary) }
                }
                Section { Text("Микрофон включается только во время удержания. Голос передаётся короткими пакетами вживую и не сохраняется как голосовое сообщение.").font(.caption).foregroundColor(.secondary) }
            }.navigationTitle("Настройки").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { model.settings = false } } }
        }.preferredColorScheme(.dark)
    }
    private var helpSheet: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text("Слышать друг друга.\nБез «алло».").font(.system(size: 32, weight: .bold, design: .rounded))
                Label("Установите приложение на два iPhone.", systemImage: "1.circle.fill")
                Label("Введите одинаковый общий код и включите рацию на обоих устройствах.", systemImage: "2.circle.fill")
                Label("Зажмите аватар друга или кнопку «Говорить всем». Отпустите, чтобы закончить.", systemImage: "3.circle.fill")
                Text("Для режима «Рядом» включите Wi-Fi и Bluetooth и оставьте приложение открытым. Для интернета укажите одинаковый WSS-сервер в настройках.").foregroundColor(.secondary)
                Text("Системный приём в фоне включается только при корректной подписи Push to Talk и настроенных push-уведомлениях сервера. Не передавайте код посторонним.").foregroundColor(.secondary)
            }.font(.system(size: 16)).padding(26) }.navigationTitle("Как это работает").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Понятно") { help = false } } }
        }.preferredColorScheme(.dark)
    }
}
