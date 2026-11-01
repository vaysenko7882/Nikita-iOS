import AccountContext
import AsyncDisplayKit
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

private enum CodeGramDestination: CaseIterable {
    case privacy, ghost, messages, archive, filters, appearance, interface, deleted, voice, storage, rules, content, peers, additional

    var title: String {
        switch self {
        case .privacy: return "Приватность"
        case .ghost: return "Режим призрака"
        case .messages: return "Сообщения"
        case .archive: return "Локальный архив"
        case .filters: return "Фильтры сообщений"
        case .appearance: return "Оформление"
        case .interface: return "Параметры интерфейса"
        case .deleted: return "Удалённые сообщения"
        case .voice: return "Студия голоса"
        case .storage: return "Хранилище и VPS"
        case .rules: return "Правила сохранения VPS"
        case .content: return "Сохранение и доступ"
        case .peers: return "Имена и аватары для себя"
        case .additional: return "Дополнительно"
        }
    }

    var detail: String {
        switch self {
        case .privacy: return "Номер и активность"
        case .ghost: return "Прочтения, онлайн и истории"
        case .messages: return "Архив и фильтры"
        case .archive: return "Удалённые сообщения и версии правок"
        case .filters: return "Скрытые отправители и фильтрация"
        case .appearance: return "Интерфейс и верхняя плашка"
        case .interface: return "Жесты, панели и элементы чата"
        case .deleted: return "Прозрачность, затемнение и пунктир"
        case .voice: return "Тембр, эффекты и свои пресеты"
        case .storage: return "Память, правила и доступ"
        case .rules: return "Группы, каналы, Архив и исключения"
        case .content: return "Копирование, истории и одноразовые медиа"
        case .peers: return "Локальные названия и фотографии"
        case .additional: return "Ресурсы и локальные функции"
        }
    }

    var symbol: String {
        switch self {
        case .privacy: return "lock.shield"
        case .ghost: return "eye.slash"
        case .messages: return "bubble.left.and.bubble.right"
        case .archive: return "archivebox"
        case .filters: return "line.3.horizontal.decrease.circle"
        case .appearance: return "rectangle.on.rectangle"
        case .interface: return "slider.horizontal.3"
        case .deleted: return "bubble.left"
        case .voice: return "waveform"
        case .storage: return "externaldrive"
        case .rules: return "checklist"
        case .content: return "square.and.arrow.down"
        case .peers: return "person.crop.circle"
        case .additional: return "slider.horizontal.3"
        }
    }

    var keywords: String {
        switch self {
        case .privacy: return "телефон скрыть номер приватность безопасность"
        case .ghost: return "невидимка призрак прочитано прочтения онлайн online typing печатает ghost сторис истории"
        case .messages: return "удаление сообщения правки версии история edits delete"
        case .archive: return "архив сохранять удаленные измененные сообщения версии история"
        case .filters: return "блокировка отправитель скрыть тень shadow фильтр"
        case .appearance: return "тема темная светлая glass стекло плашка статус бар классический дизайн"
        case .interface: return "интерфейс жесты свайп панели кнопки анимации"
        case .deleted: return "opacity прозрачность удаленных черное затемнение рамка пунктир цвет"
        case .voice: return "войсченджер voicechanger voice changer голос низкий писклявый робот эхо тембр высота пресет"
        case .storage: return "память место размер файлы мегабайты гигабайты vps сервер подключение ключ синхронизация"
        case .rules: return "фон сохранение архив исключение личные чаты каналы группы сервер vps"
        case .content: return "копировать скачать сохранить защищенный канал одноразовые медиа истории ограничения контент"
        case .peers: return "название имя аватар ава фото бот группа канал для себя"
        case .additional: return "энергосбережение ресурсы локальные функции premium премиум"
        }
    }

    func matches(_ query: String) -> Bool {
        let locale = Locale(identifier: "ru_RU")
        let haystack = "\(self.title) \(self.detail) \(self.keywords)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        return query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale).split(whereSeparator: { $0.isWhitespace }).allSatisfy { haystack.contains($0) }
    }
}

private func codegramDashboardFont(_ size: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body) -> UIFont {
    return UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight))
}

private func codegramGhostSymbol() -> UIImage {
    return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 29)).image { _ in
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 3, y: 26))
        path.addCurve(to: CGPoint(x: 4, y: 12), controlPoint1: CGPoint(x: 4, y: 21), controlPoint2: CGPoint(x: 3, y: 17))
        path.addCurve(to: CGPoint(x: 12, y: 2), controlPoint1: CGPoint(x: 4, y: 5), controlPoint2: CGPoint(x: 8, y: 2))
        path.addCurve(to: CGPoint(x: 20, y: 12), controlPoint1: CGPoint(x: 16, y: 2), controlPoint2: CGPoint(x: 20, y: 5))
        path.addCurve(to: CGPoint(x: 22, y: 26), controlPoint1: CGPoint(x: 20, y: 17), controlPoint2: CGPoint(x: 21, y: 22))
        path.addQuadCurve(to: CGPoint(x: 16, y: 23), controlPoint: CGPoint(x: 21, y: 29))
        path.addQuadCurve(to: CGPoint(x: 12, y: 26), controlPoint: CGPoint(x: 13, y: 29))
        path.addQuadCurve(to: CGPoint(x: 8, y: 23), controlPoint: CGPoint(x: 10, y: 21))
        path.addQuadCurve(to: CGPoint(x: 3, y: 26), controlPoint: CGPoint(x: 4, y: 29))
        UIColor.white.setStroke(); path.lineWidth = 1.6; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: 8, y: 10, width: 2, height: 3)).fill()
        UIBezierPath(ovalIn: CGRect(x: 15, y: 10, width: 2, height: 3)).fill()
    }.withRenderingMode(.alwaysTemplate)
}

/// Vector illustrations stay sharp at all display scales and use the current theme.
private final class CodeGramCardArtwork: UIView {
    let kind: CodeGramDestination
    init(kind: CodeGramDestination) {
        self.kind = kind
        super.init(frame: .zero)
        self.isOpaque = false; self.isUserInteractionEnabled = false; self.isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func bubble(_ rect: CGRect, color: UIColor, leftTail: Bool) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 12)
        let tail = UIBezierPath()
        if leftTail {
            tail.move(to: CGPoint(x: rect.minX + 14, y: rect.maxY - 12))
            tail.addQuadCurve(to: CGPoint(x: rect.minX - 6, y: rect.maxY + 1), controlPoint: CGPoint(x: rect.minX + 2, y: rect.maxY + 2))
            tail.addLine(to: CGPoint(x: rect.minX + 22, y: rect.maxY - 1))
        } else {
            tail.move(to: CGPoint(x: rect.maxX - 16, y: rect.maxY - 12))
            tail.addQuadCurve(to: CGPoint(x: rect.maxX + 6, y: rect.maxY + 1), controlPoint: CGPoint(x: rect.maxX - 1, y: rect.maxY + 2))
            tail.addLine(to: CGPoint(x: rect.maxX - 22, y: rect.maxY - 1))
        }
        tail.close(); path.append(tail); color.setFill(); path.fill()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let scale = min(self.bounds.width / 166, self.bounds.height / 116)
        context.saveGState()
        context.translateBy(x: (self.bounds.width - 166 * scale) / 2, y: (self.bounds.height - 116 * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        switch self.kind {
        case .privacy:
            let image = UIImage(systemName: "lock.shield", withConfiguration: UIImage.SymbolConfiguration(pointSize: 79, weight: .ultraLight))?.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
            image?.draw(in: CGRect(x: 43, y: 12, width: 80, height: 89))
        case .messages:
            self.bubble(CGRect(x: 28, y: 15, width: 105, height: 38), color: UIColor.label.withAlphaComponent(0.07), leftTail: true)
            self.bubble(CGRect(x: 41, y: 62, width: 111, height: 38), color: UIColor.label.withAlphaComponent(0.11), leftTail: false)
            ("Удалено" as NSString).draw(at: CGPoint(x: 47, y: 26), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.secondaryLabel, .strikethroughStyle: NSUnderlineStyle.single.rawValue])
            ("Изменено" as NSString).draw(at: CGPoint(x: 61, y: 73), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.label.withAlphaComponent(0.85)])
        case .appearance:
            let outline = UIBezierPath(roundedRect: CGRect(x: 12, y: 7, width: 142, height: 105), cornerRadius: 15)

            self.bubble(CGRect(x: 24, y: 21, width: 96, height: 32), color: UIColor.label.withAlphaComponent(0.16), leftTail: true)
            self.bubble(CGRect(x: 49, y: 65, width: 104, height: 33), color: UIColor.label.withAlphaComponent(0.92), leftTail: false)
            for (x, y, color) in [(CGFloat(36), CGFloat(33), UIColor.label.withAlphaComponent(0.32)), (CGFloat(62), CGFloat(77), UIColor.systemBackground.withAlphaComponent(0.6))] {
                context.setStrokeColor(color.cgColor); context.setLineWidth(3.5); context.setLineCap(.round)
                context.move(to: CGPoint(x: x, y: y)); context.addLine(to: CGPoint(x: x + 59, y: y)); context.strokePath()
                context.move(to: CGPoint(x: x, y: y + 9)); context.addLine(to: CGPoint(x: x + 37, y: y + 9)); context.strokePath()
            }
        case .voice:
            let heights: [CGFloat] = [8, 20, 13, 35, 19, 44, 24, 58, 33, 70, 49, 64, 40, 54, 25, 35, 16, 26, 11]
            context.setLineWidth(2.2); context.setLineCap(.round)
            for (index, height) in heights.enumerated() {
                context.setStrokeColor(UIColor.label.withAlphaComponent(index > 5 && index < 14 ? 0.85 : 0.38).cgColor)
                let x = CGFloat(index) * 5.6 + 10
                context.move(to: CGPoint(x: x, y: 58 - height / 2)); context.addLine(to: CGPoint(x: x, y: 58 + height / 2)); context.strokePath()
            }
            let circle = UIBezierPath(ovalIn: CGRect(x: 125, y: 39, width: 37, height: 37))
            UIColor.label.withAlphaComponent(0.12).setFill(); circle.fill()

            let triangle = UIBezierPath(); triangle.move(to: CGPoint(x: 140, y: 50)); triangle.addLine(to: CGPoint(x: 140, y: 65)); triangle.addLine(to: CGPoint(x: 151, y: 57.5)); triangle.close()
            UIColor.label.withAlphaComponent(0.85).setFill(); triangle.fill()
        default: break
        }
        context.restoreGState()
    }
}

private class CodeGramDashboardSurface: UIControl {
    private let material = CodeGramMaterialView(radius: 24)
    var action: (() -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.insertSubview(self.material, at: 0)
        self.layer.cornerRadius = 24; self.layer.cornerCurve = .continuous
        self.clipsToBounds = true
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() { super.layoutSubviews(); self.material.frame = self.bounds }
    func applyPalette(dark: Bool) { self.material.refresh() }
    override var isHighlighted: Bool {
        didSet {
            let reduced = UIAccessibility.isReduceMotionEnabled || CodeGramEnergyPolicy.current.usesReducedEffects
            let update = { self.transform = self.isHighlighted && !reduced ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity; self.alpha = self.isHighlighted ? 0.8 : 1 }
            if reduced { update() }
            else { UIView.animate(withDuration: self.isHighlighted ? 0.12 : 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: update, completion: nil) }
        }
    }
    @objc private func pressed() { self.action?() }
}

private final class CodeGramDashboardTile: CodeGramDashboardSurface {
    private let artwork: CodeGramCardArtwork
    private let caption = UILabel()
    private let detail = UILabel()
    private let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))
    init(destination: CodeGramDestination) {
        self.artwork = CodeGramCardArtwork(kind: destination)
        super.init(frame: .zero)
        self.caption.text = destination.title; self.caption.textColor = .label; self.caption.numberOfLines = 2
        self.detail.text = destination.detail; self.detail.textColor = .secondaryLabel; self.detail.numberOfLines = 2
        self.arrow.tintColor = .tertiaryLabel; self.arrow.contentMode = .scaleAspectFit
        for view in [self.artwork, self.caption, self.detail, self.arrow] { view.isUserInteractionEnabled = false; self.addSubview(view) }
        self.isAccessibilityElement = true; self.accessibilityTraits = .button
        self.refreshFonts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refreshFonts() {
        self.caption.font = codegramDashboardFont(18, weight: .semibold, style: .headline)
        self.detail.font = codegramDashboardFont(13, style: .footnote)
        self.caption.adjustsFontForContentSizeCategory = true; self.detail.adjustsFontForContentSizeCategory = true
        self.setNeedsLayout()
    }
    func setDetail(_ text: String) { self.detail.text = text; self.accessibilityLabel = "\(self.caption.text ?? ""), \(text)"; self.setNeedsLayout() }
    func preferredHeight(width: CGFloat) -> CGFloat {
        let title = self.caption.sizeThatFits(CGSize(width: max(1, width - 45), height: 150)).height
        let detail = self.detail.sizeThatFits(CGSize(width: max(1, width - 32), height: 150)).height
        return max(min(width * 0.96, 220), 94 + title + detail + 26)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let titleSize = self.caption.sizeThatFits(CGSize(width: max(1, self.bounds.width - 45), height: 150))
        let detailSize = self.detail.sizeThatFits(CGSize(width: max(1, self.bounds.width - 32), height: 150))
        let titleY = self.bounds.height - 16 - detailSize.height - 5 - titleSize.height
        self.caption.frame = CGRect(x: 16, y: titleY, width: self.bounds.width - 45, height: titleSize.height)
        self.detail.frame = CGRect(x: 16, y: self.caption.frame.maxY + 5, width: self.bounds.width - 32, height: detailSize.height)
        self.arrow.frame = CGRect(x: self.bounds.width - 27, y: titleY + max(0, titleSize.height / 2 - 7), width: 8, height: 14)
        self.artwork.frame = CGRect(x: 8, y: 8, width: self.bounds.width - 16, height: max(75, titleY - 20))
        self.artwork.setNeedsDisplay()
        self.accessibilityLabel = "\(self.caption.text ?? ""), \(self.detail.text ?? "")"
    }
    override func applyPalette(dark: Bool) { super.applyPalette(dark: dark); self.artwork.setNeedsDisplay() }
}

private final class CodeGramQuickCard: CodeGramDashboardSurface {
    private let icon: UIImageView
    private let caption = UILabel()
    private let detail = UILabel()
    private let toggle = UISwitch()
    var changed: ((Bool) -> Void)?
    init(title: String, symbol: String) {
        self.icon = UIImageView(image: symbol == "codegram.ghost" ? codegramGhostSymbol() : UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .light)))
        super.init(frame: .zero)
        self.layer.cornerRadius = 20
        self.caption.text = title; self.caption.textColor = .label
        self.detail.text = "Загрузка…"; self.detail.textColor = .secondaryLabel
        self.icon.tintColor = .label; self.icon.contentMode = .scaleAspectFit
        self.toggle.onTintColor = UIColor(white: 0.78, alpha: 1)
        self.toggle.isEnabled = false; self.toggle.accessibilityLabel = title
        self.toggle.addTarget(self, action: #selector(self.changedToggle), for: .valueChanged)
        for view in [self.icon, self.caption, self.detail, self.toggle] { self.addSubview(view) }
        self.caption.isUserInteractionEnabled = false; self.detail.isUserInteractionEnabled = false; self.icon.isUserInteractionEnabled = false
        self.accessibilityLabel = title; self.accessibilityHint = "Открыть подробные настройки"
        self.refreshFonts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refreshFonts() {
        self.caption.font = codegramDashboardFont(15, weight: .medium, style: .subheadline)
        self.detail.font = codegramDashboardFont(12, style: .caption1)
        self.caption.adjustsFontSizeToFitWidth = true; self.caption.minimumScaleFactor = 0.85
        self.detail.adjustsFontSizeToFitWidth = true; self.detail.minimumScaleFactor = 0.85
        self.setNeedsLayout()
    }
    func update(isOn: Bool, busy: Bool = false) {
        self.toggle.setOn(isOn, animated: false); self.toggle.isEnabled = !busy
        self.detail.text = busy ? "Сохранение…" : (isOn ? "Включён" : "Выключен")
        self.accessibilityValue = isOn ? "Включён" : "Выключен"
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        self.icon.frame = CGRect(x: 13, y: (self.bounds.height - 27) / 2, width: 23, height: 27)
        self.toggle.sizeToFit(); self.toggle.frame.origin = CGPoint(x: self.bounds.width - self.toggle.bounds.width - 12, y: (self.bounds.height - self.toggle.bounds.height) / 2)
        let textWidth = max(1, self.toggle.frame.minX - 50)
        let titleHeight = self.caption.font.lineHeight
        let detailHeight = self.detail.font.lineHeight
        let y = (self.bounds.height - titleHeight - detailHeight - 2) / 2
        self.caption.frame = CGRect(x: 45, y: y, width: textWidth, height: titleHeight)
        self.detail.frame = CGRect(x: 45, y: y + titleHeight + 2, width: textWidth, height: detailHeight)
    }
    @objc private func changedToggle() { self.changed?(self.toggle.isOn) }
}

private final class CodeGramDashboardRow: UIControl {
    private let icon: UIImageView
    private let caption = UILabel()
    private let detail = UILabel()
    private let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))
    var action: (() -> Void)?
    init(destination: CodeGramDestination) {
        self.icon = UIImageView(image: UIImage(systemName: destination.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .light)))
        super.init(frame: .zero)
        self.caption.text = destination.title; self.caption.textColor = .label; self.caption.numberOfLines = 2
        self.detail.text = destination.detail; self.detail.textColor = .secondaryLabel; self.detail.numberOfLines = 2
        self.icon.tintColor = .label; self.icon.contentMode = .scaleAspectFit; self.arrow.tintColor = .tertiaryLabel; self.arrow.contentMode = .scaleAspectFit
        for view in [self.icon, self.caption, self.detail, self.arrow] { view.isUserInteractionEnabled = false; self.addSubview(view) }
        self.isAccessibilityElement = true; self.accessibilityTraits = .button
        self.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.refreshFonts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refreshFonts() { self.caption.font = codegramDashboardFont(17, style: .body); self.detail.font = codegramDashboardFont(13, style: .footnote); self.setNeedsLayout() }
    func preferredHeight(width: CGFloat) -> CGFloat {
        let size = CGSize(width: max(1, width - 104), height: 200)
        return max(64, self.caption.sizeThatFits(size).height + self.detail.sizeThatFits(size).height + 26)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, self.bounds.width - 104)
        let titleHeight = self.caption.sizeThatFits(CGSize(width: width, height: 200)).height
        let detailHeight = self.detail.sizeThatFits(CGSize(width: width, height: 200)).height
        let y = (self.bounds.height - titleHeight - detailHeight - 4) / 2
        self.icon.frame = CGRect(x: 19, y: (self.bounds.height - 28) / 2, width: 27, height: 28)
        self.caption.frame = CGRect(x: 63, y: y, width: width, height: titleHeight)
        self.detail.frame = CGRect(x: 63, y: y + titleHeight + 4, width: width, height: detailHeight)
        self.arrow.frame = CGRect(x: self.bounds.width - 27, y: (self.bounds.height - 14) / 2, width: 8, height: 14)
        self.accessibilityLabel = "\(self.caption.text ?? ""), \(self.detail.text ?? "")"
    }
    override var isHighlighted: Bool { didSet { self.alpha = self.isHighlighted ? 0.55 : 1 } }
    @objc private func pressed() { self.action?() }
}

final class CodeGramDashboardController: ViewController, UISearchBarDelegate {
    private let context: AccountContext
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let logo = UIImageView(image: codegramBrandMark())
    private let searchBar = UISearchBar()
    private let searchMaterial = CodeGramMaterialView(radius: 26)
    private let ghost = CodeGramQuickCard(title: "Призрак", symbol: "codegram.ghost")
    private let archive = CodeGramQuickCard(title: "Архив", symbol: "archivebox")
    private let privacy = CodeGramDashboardTile(destination: .privacy)
    private let messages = CodeGramDashboardTile(destination: .messages)
    private let appearance = CodeGramDashboardTile(destination: .appearance)
    private let voice = CodeGramDashboardTile(destination: .voice)
    private let bottomSurface = CodeGramDashboardSurface(frame: .zero)
    private let storage = CodeGramDashboardRow(destination: .storage)
    private let additional = CodeGramDashboardRow(destination: .additional)
    private let separator = UIView()
    private let footer = UILabel()
    private let emptyLabel = UILabel()
    private var searchRows: [CodeGramDashboardRow] = []
    private var query = ""
    private var layoutSize = CGSize.zero
    private var safeInsets = UIEdgeInsets.zero
    private var dark = true
    private var classicDesign = false
    private var ghostEnabled = false
    private var archiveEnabled = false
    private var ghostBusy = false
    private var archiveBusy = false
    private let subscriptions = DisposableSet()
    private let ghostWrite = MetaDisposable()
    private let archiveWrite = MetaDisposable()
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContext) {
        self.context = context
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: context.sharedContext.currentPresentationData.with { $0 }))
        self.title = "CodeGram"
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "Назад", style: .plain, target: nil, action: nil)
        self.statusBar.statusBarStyle = context.sharedContext.currentPresentationData.with { $0 }.theme.rootController.statusBarStyle.style
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        self.subscriptions.dispose(); self.ghostWrite.dispose(); self.archiveWrite.dispose()
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.scrollView.contentInsetAdjustmentBehavior = .never; self.scrollView.keyboardDismissMode = .interactive; self.scrollView.alwaysBounceVertical = true
        self.displayNode.view.addSubview(self.scrollView); self.scrollView.addSubview(self.contentView)
        self.titleLabel.text = "CodeGram"; self.titleLabel.textColor = .label; self.titleLabel.accessibilityTraits = .header
        self.titleLabel.adjustsFontSizeToFitWidth = true; self.titleLabel.minimumScaleFactor = 0.7
        self.subtitleLabel.text = "Твой стиль. Твои настройки."; self.subtitleLabel.textColor = .secondaryLabel; self.subtitleLabel.numberOfLines = 2
        self.logo.contentMode = .scaleAspectFit; self.logo.isAccessibilityElement = false
        self.searchBar.searchTextField.insertSubview(self.searchMaterial, at: 0)
        self.searchBar.searchTextField.backgroundColor = .clear
        self.searchBar.tintColor = .label
        self.searchBar.placeholder = "Поиск"; self.searchBar.searchBarStyle = .minimal; self.searchBar.delegate = self
        self.searchBar.searchTextField.accessibilityLabel = "Поиск по настройкам CodeGram"
        self.searchBar.searchTextField.layer.cornerRadius = 21; self.searchBar.searchTextField.layer.cornerCurve = .continuous; self.searchBar.searchTextField.clipsToBounds = true
        self.searchBar.searchTextField.adjustsFontForContentSizeCategory = true
        self.searchBar.searchTextField.autocorrectionType = .no
        self.footer.text = "На этом iPhone"; self.footer.textColor = .tertiaryLabel; self.footer.textAlignment = .center
        self.emptyLabel.text = "Ничего не найдено\nПопробуй «голос», «архив» или «плашка»."; self.emptyLabel.numberOfLines = 0; self.emptyLabel.textAlignment = .center; self.emptyLabel.textColor = .secondaryLabel
        for view in [self.titleLabel, self.subtitleLabel, self.logo, self.searchBar, self.ghost, self.archive, self.privacy, self.messages, self.appearance, self.voice, self.bottomSurface, self.footer, self.emptyLabel] { self.contentView.addSubview(view) }
        self.bottomSurface.addSubview(self.storage); self.bottomSurface.addSubview(self.additional); self.bottomSurface.addSubview(self.separator)
        self.bottomSurface.isAccessibilityElement = false
        self.ghost.action = { [weak self] in self?.open(.ghost) }; self.archive.action = { [weak self] in self?.open(.archive) }
        self.ghost.changed = { [weak self] value in self?.setGhost(value) }; self.archive.changed = { [weak self] value in self?.setArchive(value) }
        self.privacy.action = { [weak self] in self?.open(.privacy) }; self.messages.action = { [weak self] in self?.open(.messages) }
        self.appearance.action = { [weak self] in self?.open(.appearance) }; self.voice.action = { [weak self] in self?.open(.voice) }
        self.storage.action = { [weak self] in self?.open(.storage) }; self.additional.action = { [weak self] in self?.open(.additional) }
        self.refreshFonts()
        self.displayNodeDidLoad()
        self.subscribeToSettings()
        self.observers.append(NotificationCenter.default.addObserver(forName: NikitaSettingsStore.changed, object: nil, queue: .main) { [weak self] _ in guard let self, self.isViewLoaded, self.displayNode.view.window != nil else { return }; self.refreshVoice() })
        self.observers.append(NotificationCenter.default.addObserver(forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshFonts(); self?.layoutContent() })
    }

    override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); if self.isViewLoaded { self.refreshVoice(); self.layoutContent() } }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let initialLayout = self.layoutSize == .zero
        self.layoutSize = layout.size; self.safeInsets = layout.safeInsets
        self.scrollView.frame = CGRect(origin: .zero, size: layout.size)
        self.scrollView.contentInset = UIEdgeInsets(top: self.cleanNavigationHeight, left: 0, bottom: layout.insets(options: .input).bottom + 16, right: 0)
        self.scrollView.scrollIndicatorInsets = self.scrollView.contentInset
        self.layoutContent()
        if initialLayout { self.scrollView.contentOffset = CGPoint(x: 0, y: -self.scrollView.contentInset.top) }
    }

    private func subscribeToSettings() {
        self.subscriptions.add((self.context.sharedContext.presentationData |> deliverOnMainQueue).start(next: { [weak self] data in self?.applyPalette(dark: data.theme.overallDarkAppearance) }))
        self.subscriptions.add((self.context.engine.messages.ghostModeSettings() |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else { return }; self.ghostEnabled = settings.isEnabled; self.ghost.update(isOn: self.ghostEnabled, busy: self.ghostBusy)
        }))
        self.subscriptions.add((self.context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: PreferencesKeys.deletedMessageArchiveSettings)) |> deliverOnMainQueue).start(next: { [weak self] entry in
            guard let self else { return }
            let settings = entry?.get(DeletedMessageArchiveSettings.self) ?? .defaultSettings
            self.archiveEnabled = settings.isEnabled
            self.archive.update(isOn: self.archiveEnabled, busy: self.archiveBusy)
        }))
        self.subscriptions.add((interfaceTuningSettingsSignal() |> deliverOnMainQueue).start(next: { [weak self] settings in
            guard let self else { return }; self.classicDesign = settings.classicDesign; self.refreshAppearanceDetail(); self.layoutContent()
        }))
        self.refreshVoice()
    }

    private func setGhost(_ value: Bool) {
        self.ghostBusy = true; self.ghost.update(isOn: value, busy: true)
        self.ghostWrite.set((self.context.engine.messages.updateGhostModeSettingsInteractively { current in var current = current; current.isEnabled = value; return current } |> deliverOnMainQueue).start(completed: { [weak self] in
            guard let self else { return }; self.ghostBusy = false; self.ghostEnabled = value; self.ghost.update(isOn: value)
        }))
    }
    private func setArchive(_ value: Bool) {
        self.archiveBusy = true; self.archive.update(isOn: value, busy: true)
        self.archiveWrite.set((self.context.engine.messages.updateDeletedMessageArchiveSettingsInteractively { current in
            var current = current; current.isEnabled = value
            if value { current.keepAcrossLaunches = true }
            return current
        } |> deliverOnMainQueue).start(completed: { [weak self] in
            guard let self else { return }; self.archiveBusy = false; self.archiveEnabled = value; self.archive.update(isOn: value)
        }))
    }
    private func refreshVoice() {
        let configuration = NikitaSettingsStore.shared.voiceConfiguration
        let title: String
        if !configuration.enabled || configuration.mix == 0 { title = "Оригинальный" }
        else if let preset = NikitaSettingsStore.shared.voicePresets.first(where: { $0.configuration == configuration }) { title = preset.title }
        else if let preset = NikitaVoiceEffect.allCases.first(where: { NikitaVoiceConfiguration.preset($0) == configuration }) { title = preset.title }
        else { title = "Свои настройки" }
        self.voice.setDetail(title); self.layoutContent()
    }
    private func refreshFonts() {
        self.titleLabel.font = codegramDashboardFont(36, weight: .bold, style: .largeTitle)
        self.subtitleLabel.font = codegramDashboardFont(15, style: .subheadline)
        self.searchBar.searchTextField.font = UIFont.preferredFont(forTextStyle: .body)
        self.footer.font = codegramDashboardFont(12, style: .caption1); self.emptyLabel.font = codegramDashboardFont(16)
        for tile in [self.privacy, self.messages, self.appearance, self.voice] { tile.refreshFonts() }
        self.ghost.refreshFonts(); self.archive.refreshFonts(); self.storage.refreshFonts(); self.additional.refreshFonts()
        for row in self.searchRows { row.refreshFonts() }
    }
    private func applyPalette(dark: Bool) {
        self.dark = dark; self.displayNode.view.overrideUserInterfaceStyle = dark ? .dark : .light
        self.displayNode.backgroundColor = CodeGramSettingsTheme.background
        self.logo.tintColor = .label
        self.logo.image = codegramBrandMark()?.withRenderingMode(.alwaysTemplate)
        self.searchBar.searchTextField.backgroundColor = .clear
        self.searchMaterial.refresh()
        self.separator.backgroundColor = .clear
        for surface in [self.ghost, self.archive, self.privacy, self.messages, self.appearance, self.voice, self.bottomSurface] as [CodeGramDashboardSurface] { surface.applyPalette(dark: dark) }
        self.refreshAppearanceDetail()
        self.layoutContent()
    }

    private func refreshAppearanceDetail() { self.appearance.setDetail(self.classicDesign ? "Классический стиль" : (self.dark ? "Тёмная · Glass" : "Светлая · Glass")) }

    private func layoutContent() {
        guard self.layoutSize.width > 0 else { return }
        let width = max(1, min(720, self.layoutSize.width - self.safeInsets.left - self.safeInsets.right - 32))
        let largeText = UIFont.preferredFont(forTextStyle: .body).pointSize > 20
        let singleColumn = width < 325 || largeText
        var y: CGFloat = 10
        let logoSize: CGFloat = largeText ? 50 : 62
        let titleY = largeText ? y + 58 : y
        let titleWidth = largeText ? width : max(1, width - 84)
        let titleHeight = self.titleLabel.font.lineHeight
        self.titleLabel.frame = CGRect(x: 8, y: titleY, width: titleWidth - 8, height: titleHeight)
        self.logo.frame = CGRect(x: width - logoSize - 10, y: y + (largeText ? 0 : 1), width: logoSize, height: logoSize + 4)
        let subtitleSize = self.subtitleLabel.sizeThatFits(CGSize(width: width - 16, height: 160))
        self.subtitleLabel.frame = CGRect(x: 8, y: self.titleLabel.frame.maxY + 4, width: width - 16, height: subtitleSize.height)
        y = max(self.logo.frame.maxY, self.subtitleLabel.frame.maxY) + 14
        let searchHeight = max(50, UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)
        self.searchBar.frame = CGRect(x: -8, y: y, width: width + 16, height: searchHeight)
        self.searchBar.layoutIfNeeded()
        self.searchMaterial.frame = self.searchBar.searchTextField.bounds
        self.searchMaterial.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        y += searchHeight + 10
        let searching = !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let home: [UIView] = [self.ghost, self.archive, self.privacy, self.messages, self.appearance, self.voice, self.bottomSurface, self.footer]
        for view in home { view.isHidden = searching }
        for row in self.searchRows { row.isHidden = !searching }
        self.emptyLabel.isHidden = !searching || !self.searchRows.isEmpty
        if searching {
            for row in self.searchRows {
                let height = row.preferredHeight(width: width)
                row.backgroundColor = CodeGramSettingsTheme.surface
                row.layer.cornerRadius = 18; row.layer.cornerCurve = .continuous
                row.frame = CGRect(x: 0, y: y, width: width, height: height); y += height + 8
            }
            if self.searchRows.isEmpty { self.emptyLabel.frame = CGRect(x: 16, y: y + 20, width: width - 32, height: 110); y += 150 }
        } else {
            let gap: CGFloat = 10
            let smallWidth = singleColumn ? width : (width - gap) / 2
            let quickHeight = max(60, UIFont.preferredFont(forTextStyle: .body).lineHeight * 2 + 20)
            self.ghost.frame = CGRect(x: 0, y: y, width: smallWidth, height: quickHeight)
            self.archive.frame = CGRect(x: singleColumn ? 0 : smallWidth + gap, y: singleColumn ? y + quickHeight + gap : y, width: smallWidth, height: quickHeight)
            y += singleColumn ? quickHeight * 2 + gap + 10 : quickHeight + 10
            let tiles = [self.privacy, self.messages, self.appearance, self.voice]
            for row in 0 ..< (singleColumn ? 4 : 2) {
                let first = row * (singleColumn ? 1 : 2)
                let count = singleColumn ? 1 : 2
                let height = (first ..< first + count).map { tiles[$0].preferredHeight(width: smallWidth) }.max() ?? 180
                for column in 0 ..< count { tiles[first + column].frame = CGRect(x: CGFloat(column) * (smallWidth + gap), y: y, width: smallWidth, height: height) }
                y += height + 10
            }
            let storageHeight = self.storage.preferredHeight(width: width)
            let additionalHeight = self.additional.preferredHeight(width: width)
            self.bottomSurface.frame = CGRect(x: 0, y: y, width: width, height: storageHeight + additionalHeight)
            self.storage.frame = CGRect(x: 0, y: 0, width: width, height: storageHeight)
            self.additional.frame = CGRect(x: 0, y: storageHeight, width: width, height: additionalHeight)
            self.separator.frame = CGRect(x: 63, y: storageHeight, width: max(0, width - 80), height: 0.5)
            y += storageHeight + additionalHeight + 16
            self.footer.frame = CGRect(x: 0, y: y, width: width, height: self.footer.font.lineHeight + 6); y = self.footer.frame.maxY + 12
        }
        self.contentView.frame = CGRect(x: max(self.safeInsets.left + 16, (self.layoutSize.width - width) / 2), y: 0, width: width, height: y)
        self.scrollView.contentSize = CGSize(width: self.layoutSize.width, height: y)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { self.query = searchText; self.rebuildSearch() }
    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { searchBar.setShowsCancelButton(true, animated: !UIAccessibility.isReduceMotionEnabled) }
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) { self.query = ""; searchBar.text = nil; searchBar.resignFirstResponder(); searchBar.setShowsCancelButton(false, animated: !UIAccessibility.isReduceMotionEnabled); self.rebuildSearch() }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private func rebuildSearch() {
        for row in self.searchRows { row.removeFromSuperview() }; self.searchRows.removeAll()
        if !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for destination in CodeGramDestination.allCases where destination.matches(self.query) {
                let row = CodeGramDashboardRow(destination: destination); row.action = { [weak self] in self?.open(destination) }
                self.contentView.addSubview(row); self.searchRows.append(row)
            }
        }
        self.layoutContent()
        self.scrollView.setContentOffset(CGPoint(x: 0, y: -self.scrollView.contentInset.top), animated: false)
    }
    private func open(_ destination: CodeGramDestination) {
        self.searchBar.resignFirstResponder()
        let controller: ViewController
        switch destination {
        case .privacy: controller = codegramSectionSettingsController(context: self.context, section: .privacy)
        case .ghost: controller = ghostModeSettingsController(context: self.context)
        case .messages: controller = CodeGramOrganizedSectionController(context: self.context, section: .messages)
        case .archive: controller = localMessageArchiveSettingsController(context: self.context)
        case .filters: controller = messageFilterSettingsController(context: self.context)
        case .appearance: controller = codegramSectionSettingsController(context: self.context, section: .appearance)
        case .interface: controller = interfaceTuningSettingsController(context: self.context)
        case .deleted: controller = CodeGramDeletedStyleController(context: self.context)
        case .voice: controller = CodeGramVoiceController(context: self.context)
        case .storage: controller = NikitaToolsController(context: self.context)
        case .rules: controller = CodeGramCapturePolicyController(context: self.context)
        case .content: controller = CodeGramContentController(context: self.context)
        case .peers: controller = CodeGramPeerAppearanceController(context: self.context)
        case .additional: controller = CodeGramOrganizedSectionController(context: self.context, section: .additional)
        }
        self.push(controller)
    }
}

private final class CodeGramOrganizedSectionController: CodeGramTableController {
    enum Section: Equatable { case messages, additional }
    private let section: Section
    init(context: AccountContext, section: Section) { self.section = section; super.init(context: context, title: section == .messages ? "Сообщения" : "Дополнительно") }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func makeSections() -> [CodeGramSettingsSection] {
        if self.section == .messages {
            return [CodeGramSettingsSection(title: "История и сохранение", footer: "Параметры локального архива относятся к этому iPhone. Фоновое сохранение на сервере настраивается в разделе «Хранилище и VPS».", rows: [
                self.textRow("Локальный архив", detail: "Удалённые сообщения и версии правок", icon: "archivebox", action: { [weak self] in guard let self else { return }; self.push(localMessageArchiveSettingsController(context: self.context)) }),
                self.textRow("Оформление удалённых", detail: "Прозрачность, затемнение и рамка", icon: "bubble.left", action: { [weak self] in guard let self else { return }; self.push(CodeGramDeletedStyleController(context: self.context)) }),
                self.textRow("Фильтры сообщений", icon: "line.3.horizontal.decrease.circle", action: { [weak self] in guard let self else { return }; self.push(messageFilterSettingsController(context: self.context)) }),
                self.textRow("Сохранение и доступ", detail: "Копирование, истории и одноразовые медиа", icon: "square.and.arrow.down", action: { [weak self] in guard let self else { return }; self.push(CodeGramContentController(context: self.context)) }) ])]
        } else {
            return [CodeGramSettingsSection(title: "На этом iPhone", footer: "Локальный вид, ресурсы и дополнительные возможности клиента.", rows: [
                self.textRow("Имена и аватары для себя", icon: "person.crop.circle", action: { [weak self] in guard let self else { return }; self.push(CodeGramPeerAppearanceController(context: self.context)) }),
                self.textRow("Ресурсы и локальные функции", detail: "Энергосбережение и локальные возможности", icon: "slider.horizontal.3", action: { [weak self] in guard let self else { return }; self.push(codegramSectionSettingsController(context: self.context, section: .additional)) }) ])]
        }
    }
}

