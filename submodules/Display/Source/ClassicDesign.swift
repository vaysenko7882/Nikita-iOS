import Foundation
import UIKit

public enum ClassicDesign {
    /// Layout policy only: keep the modern interface and its original geometry.
    /// A saved legacy preference must not switch the fork back to old layouts.
    public static var isEnabled: Bool {
        get { return false }
        set { }
    }

    @MainActor public static func installOpaqueSystemAppearance() {
        if #available(iOS 13.0, *) {
            let navigation = UINavigationBarAppearance()
            navigation.backgroundEffect = nil
            navigation.backgroundColor = .systemBackground
            let navigationBar = UINavigationBar.appearance()
            navigationBar.standardAppearance = navigation
            navigationBar.compactAppearance = navigation
            navigationBar.scrollEdgeAppearance = navigation

            let toolbar = UIToolbarAppearance()
            toolbar.backgroundEffect = nil
            toolbar.backgroundColor = .systemBackground
            let toolbars = UIToolbar.appearance()
            toolbars.standardAppearance = toolbar
            toolbars.compactAppearance = toolbar

            let tab = UITabBarAppearance()
            tab.backgroundEffect = nil
            tab.backgroundColor = .systemBackground
            let tabBars = UITabBar.appearance()
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

/// Material policy is deliberately independent of the layout selector above.
/// Modern controls retain their dimensions, clipping shapes and content hosts
/// while using an inexpensive opaque fill instead of a sampled backdrop.
public enum GlassEffects {
    public static var isEnabled: Bool { return false }
}
