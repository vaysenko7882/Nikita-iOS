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
    public static var current: CodeGramDeletedStyle {
        get {
            return (UserDefaults.standard.data(forKey: "codegram.deletedStyle").flatMap {
                try? JSONDecoder().decode(CodeGramDeletedStyle.self, from: $0)
            } ?? CodeGramDeletedStyle()).normalized
        }
        set {
            if let data = try? JSONEncoder().encode(newValue.normalized) {
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
    init(root: CALayer) {
        self.root = root
        self.shape.zPosition = 1000
        self.observer = NotificationCenter.default.addObserver(forName: CodeGramDeletedStyle.changed, object: nil, queue: .main) { [weak self] _ in self?.apply() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func apply() {
        guard let root else { return }
        let style = CodeGramDeletedStyle.current
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
        decoration = CodeGramDeletedDecoration(root: root)
        objc_setAssociatedObject(root, &codegramDeletedDecorationKey, decoration, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    decoration.rect = rect
    decoration.deleted = isDeleted
    decoration.circular = circular
    decoration.apply()
}
