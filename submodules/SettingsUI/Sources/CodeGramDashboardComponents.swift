import UIKit

enum CodeGramDestination: CaseIterable {
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
        case .additional: return "gearshape.2"
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

func codegramDashboardFont(_ size: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body) -> UIFont {
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

final class CodeGramDashboardTile: CodeGramDashboardSurface {
    private let artwork: CodeGramCardArtwork
    private let caption = UILabel()
    private let detail = UILabel()
    private let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))
    init(destination: CodeGramDestination) {
        self.artwork = CodeGramCardArtwork(kind: destination)
        super.init()
        self.caption.text = destination.title; self.caption.textColor = .label; self.caption.numberOfLines = 2
        self.detail.text = destination.detail; self.detail.textColor = .secondaryLabel; self.detail.numberOfLines = 2
        self.arrow.tintColor = .tertiaryLabel; self.arrow.contentMode = .scaleAspectFit
        for view in [self.artwork, self.caption, self.detail, self.arrow] { view.isUserInteractionEnabled = false; self.contentView.addSubview(view) }
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
        let title = self.caption.sizeThatFits(CGSize(width: max(1, width - 45), height: .greatestFiniteMagnitude)).height
        let detail = self.detail.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)).height
        return max(min(width * 0.96, 220), 94 + title + detail + 26)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let titleSize = self.caption.sizeThatFits(CGSize(width: max(1, self.bounds.width - 45), height: .greatestFiniteMagnitude))
        let detailSize = self.detail.sizeThatFits(CGSize(width: max(1, self.bounds.width - 32), height: .greatestFiniteMagnitude))
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

final class CodeGramQuickCard: CodeGramDashboardSurface {
    private let icon: UIImageView
    private let caption = UILabel()
    private let detail = UILabel()
    private let toggle = UISwitch()
    var changed: ((Bool) -> Void)?
    init(title: String, symbol: String) {
        self.icon = UIImageView(image: symbol == "codegram.ghost" ? codegramGhostSymbol() : UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 24, weight: .light)))
        super.init()
                self.caption.text = title; self.caption.textColor = .label
        self.detail.text = "Загрузка…"; self.detail.textColor = .secondaryLabel
        self.icon.tintColor = .label; self.icon.contentMode = .scaleAspectFit
        self.toggle.onTintColor = UIColor(white: 0.78, alpha: 1)
        self.toggle.isEnabled = false; self.toggle.accessibilityLabel = title
        self.toggle.addTarget(self, action: #selector(self.changedToggle), for: .valueChanged)
        for view in [self.icon, self.caption, self.detail, self.toggle] { self.contentView.addSubview(view) }
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

final class CodeGramDashboardRow: CodeGramDashboardSurface {
    private let icon: UIImageView
    private let caption = UILabel()
    private let detail = UILabel()
    private let arrow = UIImageView(image: UIImage(systemName: "chevron.right"))
    init(destination: CodeGramDestination) {
        self.icon = UIImageView(image: UIImage(systemName: destination.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .light)))
        super.init()
        self.caption.text = destination.title; self.caption.textColor = .label; self.caption.numberOfLines = 2
        self.detail.text = destination.detail; self.detail.textColor = .secondaryLabel; self.detail.numberOfLines = 2
        self.icon.tintColor = .label; self.icon.contentMode = .scaleAspectFit; self.arrow.tintColor = .tertiaryLabel; self.arrow.contentMode = .scaleAspectFit
        for view in [self.icon, self.caption, self.detail, self.arrow] { view.isUserInteractionEnabled = false; self.contentView.addSubview(view) }
        self.isAccessibilityElement = true; self.accessibilityTraits = .button
        self.refreshFonts()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func refreshFonts() { self.caption.font = codegramDashboardFont(17, style: .body); self.detail.font = codegramDashboardFont(13, style: .footnote); self.setNeedsLayout() }
    func preferredHeight(width: CGFloat) -> CGFloat {
        let size = CGSize(width: max(1, width - 104), height: .greatestFiniteMagnitude)
        return max(64, self.caption.sizeThatFits(size).height + self.detail.sizeThatFits(size).height + 26)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, self.bounds.width - 104)
        let titleHeight = self.caption.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let detailHeight = self.detail.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let y = (self.bounds.height - titleHeight - detailHeight - 4) / 2
        self.icon.frame = CGRect(x: 19, y: (self.bounds.height - 28) / 2, width: 27, height: 28)
        self.caption.frame = CGRect(x: 63, y: y, width: width, height: titleHeight)
        self.detail.frame = CGRect(x: 63, y: y + titleHeight + 4, width: width, height: detailHeight)
        self.arrow.frame = CGRect(x: self.bounds.width - 27, y: (self.bounds.height - 14) / 2, width: 8, height: 14)
        self.accessibilityLabel = "\(self.caption.text ?? ""), \(self.detail.text ?? "")"
    }
}

