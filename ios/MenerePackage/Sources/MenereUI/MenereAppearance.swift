import SwiftUI
import UIKit

/// Global UIKit appearance configuration for the brand chrome. Call `apply()` once at launch.
public enum MenereAppearance {
    /// Configures the global `UINavigationBar` appearance with an OPAQUE parchment background and ink
    /// title text. This removes the default white nav-bar / status-bar seam that would otherwise show
    /// above parchment content on every screen at once.
    ///
    /// The tab bar is deliberately left untouched so the iOS 26 floating "glass" tab bar keeps its
    /// translucent default, which already reads fine over parchment.
    public static func apply() {
        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor = .parchmentUI
        navBar.shadowColor = .clear
        navBar.titleTextAttributes = [.foregroundColor: UIColor.inkUI]
        navBar.largeTitleTextAttributes = [.foregroundColor: UIColor.inkUI]

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = navBar
        proxy.scrollEdgeAppearance = navBar
        proxy.compactAppearance = navBar
    }
}
