import AccountContext
import Display
import Foundation
import PhotosUI
import SwiftSignalKit
import TelegramCore
import UIKit

final class CodeGramPeerAppearanceController: CodeGramTableController {
    private var peers: [EnginePeer] = []
    private let disposable = MetaDisposable()
    init(context: AccountContext) { super.init(context: context, title: "Имена и аватары для себя") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.disposable.dispose() }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.disposable.set((self.context.engine.codegramLocalPeerAppearances() |> deliverOnMainQueue).start(next: { [weak self] peers in self?.peers = peers; self?.reloadContent() }))
    }
    override func makeSections() -> [CodeGramSettingsSection] {
        return [
            CodeGramSettingsSection(title: "Только на этом iPhone", footer: "Меняет видимое тебе название и аватар. Другие участники видят оригинал; запросы изменения профиля в Telegram не отправляются. Сервер VPS продолжит показывать оригинальные названия.", rows: [self.textRow("Выбрать канал, группу или бота", icon: "person.crop.circle.badge.plus", action: { [weak self] in self?.selectPeer() })]),
            CodeGramSettingsSection(title: "Твои настройки", footer: "После смены аватара открытый большой просмотр фото может показывать оригинал Telegram. Локальная картинка используется в аватарах списка и заголовков.", rows: self.peers.map { peer in
                let value = CodeGramPeerAppearanceStore.shared.appearance(peer.id)
                return self.textRow(peer.debugDisplayTitle, detail: [value.title == nil ? nil : "Своё имя", value.avatar == nil ? nil : "Свой аватар"].compactMap { $0 }.joined(separator: " · "), icon: "person.crop.circle", action: { [weak self] in guard let self else { return }; self.push(CodeGramPeerEditorController(context: self.context, peer: peer)) })
            })
        ]
    }
    private func selectPeer() {
        let selection = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(context: self.context, filter: [.excludeSecretChats, .doNotSearchMessages], hasFilters: true, hasContactSelector: false, title: "Локальный вид"))
        selection.peerSelected = { [weak self] peer, _ in
            guard let self else { return }
            if case let .user(user) = peer, user.botInfo == nil {
                self.notice("Здесь можно настроить каналы, группы и ботов."); return
            }
            self.push(CodeGramPeerEditorController(context: self.context, peer: peer))
        }
        self.push(selection)
    }
}

private final class CodeGramPeerEditorController: CodeGramTableController, PHPickerViewControllerDelegate {
    private let peer: EnginePeer
    private let field = UITextField()
    private let disposable = MetaDisposable()
    private var jpeg: Data?
    private var removeAvatar = false
    init(context: AccountContext, peer: EnginePeer) {
        self.peer = peer
        super.init(context: context, title: "Вид для себя")
        self.field.text = CodeGramPeerAppearanceStore.shared.appearance(peer.id).title
        self.field.placeholder = peer.debugDisplayTitle
        self.field.clearButtonMode = .whileEditing
        self.field.autocapitalizationType = .sentences
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Сохранить", style: .done, target: self, action: #selector(self.save))
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit { self.disposable.dispose() }
    override func makeSections() -> [CodeGramSettingsSection] {
        let appearance = CodeGramPeerAppearanceStore.shared.appearance(self.peer.id)
        let data = self.removeAvatar ? nil : (self.jpeg ?? CodeGramPeerAppearanceStore.shared.imageData(appearance))
        return [
            CodeGramSettingsSection(title: "Название", footer: "Пустое поле возвращает оригинальное название. До 128 символов.", rows: [CodeGramSettingsRow(cell: { [weak self] in
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                if let self { self.field.removeFromSuperview(); self.field.translatesAutoresizingMaskIntoConstraints = false; cell.contentView.addSubview(self.field)
                    NSLayoutConstraint.activate([self.field.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16), self.field.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16), self.field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 16), self.field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -16)]) }
                cell.selectionStyle = .none; return cell
            })]),
            CodeGramSettingsSection(title: "Аватар", footer: "Картинка обрезается по центру до квадрата и остаётся только на устройстве.", rows: [
                CodeGramSettingsRow(cell: {
                    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                    cell.textLabel?.text = data == nil ? "Оригинал Telegram" : "Свой аватар"
                    if let data, let image = UIImage(data: data) {
                        cell.imageView?.image = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 44, height: 44)) }
                        cell.imageView?.layer.cornerRadius = 22; cell.imageView?.clipsToBounds = true
                    } else { cell.imageView?.image = UIImage(systemName: "person.crop.circle") }
                    cell.selectionStyle = .none
                    return cell
                }),
                self.textRow("Выбрать фото", icon: "photo", action: { [weak self] in self?.choosePhoto() }),
                self.textRow("Вернуть оригинальный аватар", action: { [weak self] in self?.jpeg = nil; self?.removeAvatar = true; self?.reloadContent() })]),
            CodeGramSettingsSection(title: nil, footer: "Изменения появятся в списке чатов и заголовках после сохранения. Аватар и название у остальных участников не меняются.", rows: [self.textRow("Сбросить локальный вид", action: { [weak self] in self?.reset() })])
        ]
    }
    private func choosePhoto() {
        var configuration = PHPickerConfiguration(); configuration.filter = .images; configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration); picker.delegate = self
        self.present(picker, animated: true)
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage, image.size.width > 0, image.size.height > 0 else { return }
            let scale = max(512 / image.size.width, 512 / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let output = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { renderer in
                UIColor.black.setFill(); renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
                image.draw(in: CGRect(x: (512 - size.width) / 2, y: (512 - size.height) / 2, width: size.width, height: size.height))
            }.jpegData(compressionQuality: 0.85)
            DispatchQueue.main.async { self?.jpeg = output; self?.removeAvatar = false; self?.reloadContent() }
        }
    }
    @objc private func save() {
        self.view.endEditing(true)
        self.disposable.set((self.context.engine.updateCodeGramPeerAppearance( peerId: self.peer.id, title: self.field.text, jpeg: self.jpeg, removeAvatar: self.removeAvatar) |> deliverOnMainQueue).start(next: { [weak self] success in
            guard let self else { return }
            self.notice(success ? "Сохранено только для тебя на этом iPhone." : "Не удалось сохранить. Попробуй ещё раз.")
        }))
    }
    private func reset() {
        self.disposable.set((self.context.engine.updateCodeGramPeerAppearance( peerId: self.peer.id, title: nil, reset: true) |> deliverOnMainQueue).start(next: { [weak self] success in
            guard let self else { return }
            if success { self.jpeg = nil; self.removeAvatar = false; self.field.text = nil; self.reloadContent() }
            self.notice(success ? "Восстановлен оригинальный вид Telegram." : "Не удалось сбросить настройки.")
        }))
    }
}
