import Foundation
import UIKit
import Display
import ComponentFlow

/// Uses actual production view/shape/clipping implementations. The separate
/// dependency adapters only apply immediate property updates.
private final class MaterialFixtureController: UIViewController {
    private let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private var failures: [String] = []
    private var checks = 0
    private var started = false
    private var surfaces: [(String, GlassBackgroundView, CGSize, CGFloat)] = []
    private let custom = GlassBackgroundView(frame: CGRect(x: 24, y: 380, width: 300, height: 96))
    private let customRadii = GlassBackgroundView.CornerRadii(topLeft: 30, topRight: 30, bottomLeft: 12, bottomRight: 12)
    private let group = GlassBackgroundContainerView(spacing: 7)

    override func viewDidLoad() {
        super.viewDidLoad()
        self.overrideUserInterfaceStyle = .dark
        self.view.backgroundColor = UIColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        let title = UILabel(frame: CGRect(x: 24, y: 90, width: 370, height: 40))
        title.text = "Современные формы · без стекла"
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontSizeToFitWidth = true
        title.textColor = .label
        self.view.addSubview(title)
        self.addSurface("circle", frame: CGRect(x: 24, y: 160, width: 56, height: 56), radius: 28, title: "●")
        self.addSurface("pill", frame: CGRect(x: 110, y: 163, width: 180, height: 50), radius: 25, title: "Плавающая кнопка")
        self.addSurface("panel", frame: CGRect(x: 24, y: 250, width: 300, height: 96), radius: 30, title: "Современная панель")
        self.custom.update(size: self.custom.bounds.size, cornerRadii: self.customRadii, isDark: true, tintColor: .init(kind: .panel), isInteractive: true, transition: .immediate)
        self.view.addSubview(self.custom)
        self.addLabel("Разные радиусы углов", to: self.custom)
        self.group.frame = CGRect(x: 24, y: 520, width: 300, height: 54)
        self.group.update(size: self.group.bounds.size, isDark: true, transition: .immediate)
        self.view.addSubview(self.group)
        self.addSurface("nav-group", frame: CGRect(origin: .zero, size: self.group.bounds.size), radius: 27, title: "Группа навигации", parent: self.group.contentView)
    }

    private func addSurface(_ name: String, frame: CGRect, radius: CGFloat, title: String, parent: UIView? = nil) {
        let surface = GlassBackgroundView(frame: frame)
        surface.update(size: frame.size, cornerRadius: radius, isDark: true, tintColor: .init(kind: .panel), isInteractive: true, transition: .immediate)
        (parent ?? self.view).addSubview(surface)
        self.addLabel(title, to: surface)
        self.surfaces.append((name, surface, frame.size, radius))
    }

    private func addLabel(_ title: String, to surface: GlassBackgroundView) {
        let label = UILabel(frame: surface.contentView.bounds.insetBy(dx: 8, dy: 2))
        label.text = title
        label.textColor = .label
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        surface.contentView.addSubview(label)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !self.started else { return }
        self.started = true
        self.check(!ClassicDesign.isEnabled, "Modern layout must be selected before the first frame")
        ClassicDesign.isEnabled = true
        self.check(!ClassicDesign.isEnabled, "A stored legacy preference must not change geometry")
        self.check(!GlassEffects.isEnabled, "Sampled glass material must be disabled")
        self.verify(isDark: true)
        self.phase("01-modern-material-dark") { [weak self] in
            guard let self else { return }
            self.overrideUserInterfaceStyle = .light
            self.view.backgroundColor = UIColor(white: 0.91, alpha: 1)
            self.verify(isDark: false)
            self.phase("02-modern-material-light") { [weak self] in self?.finish() }
        }
    }

    private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        if !condition() { self.failures.append(message) }
    }

    private func descendants(_ root: UIView) -> [UIView] {
        return [root] + root.subviews.flatMap { self.descendants($0) }
    }

    private func layerTree(_ root: CALayer) -> [CALayer] {
        return [root] + (root.sublayers ?? []).flatMap { self.layerTree($0) }
    }

    private func verify(isDark: Bool) {
        let suffix = isDark ? "dark" : "light"
        for (name, surface, size, radius) in self.surfaces {
            let frame = surface.frame
            surface.update(size: size, cornerRadius: radius, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: .immediate)
            self.check(surface.frame == frame, "\(name) \(suffix): material update changed caller frame")
            self.check(surface.params?.shape == .roundedRect(cornerRadius: radius), "\(name) \(suffix): caller radius changed")
            self.check(surface.contentView.frame == CGRect(origin: .zero, size: size), "\(name) \(suffix): content frame changed")
            self.check(surface.contentView.bounds == CGRect(origin: .zero, size: size), "\(name) \(suffix): content bounds changed")
            let views = self.descendants(surface)
            self.check(!views.contains { $0 is UIVisualEffectView }, "\(name) \(suffix): backdrop effect view was created")
            let material = views.first { String(describing: type(of: $0)).contains("ClassicGlassMaterialView") }
            self.check(material?.frame == CGRect(origin: .zero, size: size), "\(name) \(suffix): actual opaque material frame changed")
            self.check(material?.layer.cornerRadius == radius, "\(name) \(suffix): actual clipping radius changed")
            self.check(self.layerTree(surface.layer).allSatisfy { ($0.filters ?? []).isEmpty }, "\(name) \(suffix): a backdrop filter was installed")
        }
        let frame = self.custom.frame
        self.custom.update(size: frame.size, cornerRadii: self.customRadii, isDark: isDark, tintColor: .init(kind: .panel), isInteractive: true, transition: .immediate)
        self.check(self.custom.frame == frame, "\(suffix): asymmetric panel frame changed")
        self.check(self.custom.params?.shape == .customRoundedRect(cornerRadii: self.customRadii), "\(suffix): asymmetric corner radii changed")
        self.check(!self.descendants(self.custom).contains { $0 is UIVisualEffectView }, "\(suffix): asymmetric panel created a backdrop")
        let groupFrame = self.group.frame
        self.group.update(size: groupFrame.size, isDark: isDark, transition: .immediate)
        self.check(self.group.frame == groupFrame && self.group.contentView.frame == CGRect(origin: .zero, size: groupFrame.size), "\(suffix): navigation group frame changed")
        self.check(self.group.spacing == 7 && !GlassBackgroundContainerView.mergesShapes, "\(suffix): group spacing changed or optical merging enabled")
        self.check(!self.descendants(self.group).contains { $0 is UIVisualEffectView }, "\(suffix): navigation container created a backdrop")
    }

    private func phase(_ name: String, completion: @escaping () -> Void) {
        try? name.write(to: self.output.appendingPathComponent("phase.txt"), atomically: true, encoding: .utf8)
        let started = Date()
        func poll() {
            if FileManager.default.fileExists(atPath: self.output.appendingPathComponent("captured-" + name).path) {
                completion()
            } else if Date().timeIntervalSince(started) > 120 {
                self.failures.append("Timed out waiting for screenshot: " + name)
                self.finish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
    }

    private func finish() {
        let report: [String: Any] = [
            "checks": self.checks,
            "failures": self.failures,
            "classic_layout": ClassicDesign.isEnabled,
            "glass_effects": GlassEffects.isEnabled,
            "scope": "Actual production GlassBackgroundView prefix and ClassicGlassMaterialView; immediate dependency adapters; no full Telegram/account integration."
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: self.output.appendingPathComponent("result.json"), options: .atomic)
        }
    }
}

private final class MaterialFixtureScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MaterialFixtureController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@main
private final class ModernMaterialFixtureApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "ModernMaterial", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MaterialFixtureScene.self
        return configuration
    }
}
