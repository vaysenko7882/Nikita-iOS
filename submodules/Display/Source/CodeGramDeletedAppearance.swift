import Foundation
import UIKit
import ObjectiveC

public struct CodeGramDeletedStyle: Codable, Equatable {
    public var opacity: Double = 0.48
    public var darkOverlay: Double = 0
    public var dashed: Bool = false
    public var outlineWidth: Double = 1
    public var cornerRadius: Double = 17
    public var outlineColor: Int = 0
    public init() {}
    public var normalized: CodeGramDeletedStyle {
        var value = self
        func clamp(_ value: Double, _ low: Double, _ high: Double, _ fallback: Double) -> Double {
            return value.isFinite ? min(high, max(low, value)) : fallback
        }
        value.opacity = clamp(self.opacity, 0.1, 1, 0.48)
        value.darkOverlay = clamp(self.darkOverlay, 0, 0.85, 0)
        value.outlineWidth = clamp(self.outlineWidth, 0.5, 3, 1)
        value.cornerRadius = clamp(self.cornerRadius, 4, 30, 17)
        value.outlineColor = min(3, max(0, self.outlineColor))
        return value
    }
    public var color: UIColor {
        return [UIColor.systemGray, .systemBlue, .systemOrange, .systemRed][self.normalized.outlineColor]
    }
    public static let changed = Notification.Name("CodeGramDeletedStyleChanged")
    private static let cacheLock = NSLock()
    private static var cached: CodeGramDeletedStyle = (UserDefaults.standard.data(forKey: "codegram.deletedStyle").flatMap {
        try? JSONDecoder().decode(CodeGramDeletedStyle.self, from: $0)
    } ?? CodeGramDeletedStyle()).normalized
    public static var current: CodeGramDeletedStyle {
        get {
            self.cacheLock.lock(); defer { self.cacheLock.unlock() }
            return self.cached
        }
        set {
            let value = newValue.normalized
            self.cacheLock.lock()
            guard self.cached != value else { self.cacheLock.unlock(); return }
            self.cached = value
            self.cacheLock.unlock()
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: "codegram.deletedStyle")
                NotificationCenter.default.post(name: Self.changed, object: nil)
            }
        }
    }
}

private final class CodeGramDeletedDecoration {
    weak var root: CALayer?
    let shape = CAShapeLayer()
    var rect = CGRect.zero
    var deleted = false
    var circular = false
    var observer: NSObjectProtocol?
    private var appliedStyle: CodeGramDeletedStyle?
    private var appliedRect = CGRect.null
    private var appliedDeleted = false
    private var appliedCircular = false
    init(root: CALayer) {
        self.root = root
        self.shape.zPosition = 1000
        self.observer = NotificationCenter.default.addObserver(forName: CodeGramDeletedStyle.changed, object: nil, queue: .main) { [weak self] _ in self?.apply() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func apply() {
        guard let root else { return }
        let style = CodeGramDeletedStyle.current
        guard self.appliedStyle != style || self.appliedRect != self.rect || self.appliedDeleted != self.deleted || self.appliedCircular != self.circular || root.opacity != (self.deleted ? Float(style.opacity) : 1) else { return }
        self.appliedStyle = style; self.appliedRect = self.rect
        self.appliedDeleted = self.deleted; self.appliedCircular = self.circular
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.opacity = self.deleted ? Float(style.opacity) : 1
        if self.deleted && (style.dashed || style.darkOverlay > 0) {
            if self.shape.superlayer !== root { root.addSublayer(self.shape) }
            self.shape.frame = self.rect
            let radius = self.circular ? self.rect.height / 2 : CGFloat(style.cornerRadius)
            self.shape.path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: self.rect.size).insetBy(dx: 1, dy: 1), cornerRadius: radius).cgPath
            self.shape.fillColor = UIColor.black.withAlphaComponent(CGFloat(style.darkOverlay)).cgColor
            self.shape.strokeColor = style.dashed ? style.color.cgColor : UIColor.clear.cgColor
            self.shape.lineWidth = CGFloat(style.outlineWidth)
            self.shape.lineDashPattern = style.dashed ? [5, 4] : nil
        } else { self.shape.removeFromSuperlayer() }
        CATransaction.commit()
    }
}

private var codegramDeletedDecorationKey: UInt8 = 0
public func codegramApplyDeletedAppearance(root: CALayer, rect: CGRect, isDeleted: Bool, circular: Bool = false) {
    let decoration: CodeGramDeletedDecoration
    if let current = objc_getAssociatedObject(root, &codegramDeletedDecorationKey) as? CodeGramDeletedDecoration {
        decoration = current
    } else {
        // Ordinary messages need no decoration, observer or preferences decode.
        guard isDeleted else { return }
        decoration = CodeGramDeletedDecoration(root: root)
        objc_setAssociatedObject(root, &codegramDeletedDecorationKey, decoration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    decoration.rect = rect
    decoration.deleted = isDeleted
    decoration.circular = circular
    decoration.apply()
}

