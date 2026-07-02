import SwiftUI
import UIKit

/// Global UIKit appearance configuration for the brand chrome. Call `apply()` once at launch.
public enum MenereAppearance {
    /// Configures the global `UINavigationBar` appearance with an OPAQUE family-canvas (warm
    /// daylight cream) background and ink titles in chunky SF Rounded — the family identity's
    /// chrome. This removes the default white nav-bar / status-bar seam that would otherwise show
    /// above the canvas on every screen at once.
    ///
    /// The wine stack (Cellar/Scan/Journal/BottleCard) opts back OUT of this per-screen by pinning
    /// `.toolbarBackground(Color.parchment, for: .navigationBar)` so stepping from the cream family
    /// surfaces into the parchment Cellar reads as entering the wine cellar — that seam is
    /// intentional.
    ///
    /// The tab bar is deliberately left untouched so the iOS 26 floating "glass" tab bar keeps its
    /// translucent default, which reads fine over the family canvas.
    public static func apply() {
        let navBar = UINavigationBarAppearance()
        navBar.configureWithOpaqueBackground()
        navBar.backgroundColor = .familyCanvasUI
        navBar.shadowColor = .clear
        navBar.titleTextAttributes = [
            .foregroundColor: UIColor.inkUI,
            .font: roundedFont(size: 17, weight: .semibold),
        ]
        navBar.largeTitleTextAttributes = [
            .foregroundColor: UIColor.inkUI,
            .font: roundedFont(size: 34, weight: .heavy),
        ]

        let proxy = UINavigationBar.appearance()
        proxy.standardAppearance = navBar
        proxy.scrollEdgeAppearance = navBar
        proxy.compactAppearance = navBar
    }

    /// SF Rounded at a given size/weight, falling back to the plain system font if the rounded
    /// descriptor is unavailable.
    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

public extension View {
    /// Pins the wine-era "Cellar & Candlelight" chrome on a wine-stack screen (Cellar / Scan /
    /// BottleCard / Journal) so the global family appearance doesn't leak in: an opaque parchment
    /// nav bar plus the wine tint. Walking from the cream family surfaces into these screens should
    /// feel like stepping into a wine cellar — apply this to every screen inside that seam.
    func wineChrome() -> some View {
        self
            .toolbarBackground(Color.parchment, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .tint(.wine)
    }
}
