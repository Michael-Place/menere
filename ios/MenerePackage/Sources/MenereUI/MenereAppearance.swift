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

    /// A wine-stack nav title in New York serif. The global family appearance
    /// (`MenereAppearance.apply()`) pins ALL nav titles to chunky SF Rounded — the family identity's
    /// chrome — which otherwise leaks into the Cellar stack. This restores the "Cellar & Candlelight"
    /// serif per-screen by hiding the native (rounded) title and rendering the title as a serif
    /// `principal` toolbar item instead. `navigationTitle` is kept for the back-button label +
    /// accessibility; the display mode is forced inline so the rounded large title never shows.
    /// Overriding the shared `UINavigationBar` large-title font per-screen would leak into the family
    /// screens sharing the same nav stack, so an inline serif title is the safe, contained choice.
    /// Pair with `.wineChrome()`.
    func wineNavTitle(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.system(.headline, design: .serif).weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}
