import Foundation
import UIKit

public enum ClassicDesign {
    /// This fork uses the existing classic layout paths from its first frame.
    /// Keep the setter for older preference/bootstrap callers; saved settings
    /// must never turn Liquid Glass back on.
    public static var isEnabled: Bool {
        get { return true }
        set { }
    }

    @MainActor public static func installOpaqueSystemAppearance() {
        if #available(iOS 13.0, *) {
            let navigation = UINavigationBarAppearance()
            navigation.configureWithOpaqueBackground()
            navigation.backgroundEffect = nil
            navigation.backgroundColor = .systemBackground
            let navigationBar = UINavigationBar.appearance()
            navigationBar.isTranslucent = false
            navigationBar.standardAppearance = navigation
            navigationBar.compactAppearance = navigation
            navigationBar.scrollEdgeAppearance = navigation

            let toolbar = UIToolbarAppearance()
            toolbar.configureWithOpaqueBackground()
            toolbar.backgroundEffect = nil
            toolbar.backgroundColor = .systemBackground
            let toolbars = UIToolbar.appearance()
            toolbars.isTranslucent = false
            toolbars.standardAppearance = toolbar
            toolbars.compactAppearance = toolbar

            let tab = UITabBarAppearance()
            tab.configureWithOpaqueBackground()
            tab.backgroundEffect = nil
            tab.backgroundColor = .systemBackground
            let tabBars = UITabBar.appearance()
            tabBars.isTranslucent = false
            tabBars.standardAppearance = tab
            if #available(iOS 15.0, *) {
                navigationBar.compactScrollEdgeAppearance = navigation
                toolbars.scrollEdgeAppearance = toolbar
                toolbars.compactScrollEdgeAppearance = toolbar
                tabBars.scrollEdgeAppearance = tab
            }
        }
    }
}
