import SwiftUI
import UIKit

/// Global UIKit appearance configuration for the brand chrome. Call `apply()` once at launch.
public enum MenereAppearance {
    /// Configures the global `UINavigationBar` appearance with an OPAQUE family-canvas (warm
    /// daylight cream) background and ink titles in chunky SF Rounded — the family identity's
    /// chrome. This removes the default white nav-bar / status-bar seam that would otherwise show
    /// above the canvas on every screen at once.
    ///
    /// The wine stack (Cellar/Scan/Journal/BottleCard) now shares this same family chrome via
    /// `.wineChrome()` (which re-pins `familyCanvas` + the `bacanGreen` tint), so the cellar reads as
    /// the same app as every other surface rather than a separate parchment world.
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
    /// Applies the Bacán family chrome to a wine-stack screen (Cellar / Scan / BottleCard / Journal):
    /// the daylight-cream `familyCanvas` nav bar plus the `bacanGreen` tint. Historically this pinned
    /// the wine-era "Cellar & Candlelight" parchment + Bordeaux chrome so the Cellar read as a separate
    /// heritage world; the app has since unified on one identity, so the cellar now wears the same warm
    /// family chrome as every other surface. The modifier name is kept so all wine-stack call sites
    /// stay untouched. The `familyCanvas` toolbar background matches `MenereAppearance.apply()` (so
    /// it's belt-and-suspenders here), and the `bacanGreen` tint flips the wine screens' controls off
    /// the old wine red onto the family primary.
    func wineChrome() -> some View {
        self
            .toolbarBackground(Color.familyCanvas, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            .tint(.bacanGreen)
    }

    /// An inline nav title for a wine-stack screen, rendered in the family's chunky SF Rounded to match
    /// every other Bacán surface. The global family appearance (`MenereAppearance.apply()`) already
    /// pins nav titles to SF Rounded, so this mainly forces the inline display mode the wine screens
    /// want (the Cellar's segmented control sits directly under the bar, so a large title would crowd
    /// it) while keeping `navigationTitle` for the back-button label + accessibility. Previously this
    /// restored a New York serif title for the "Cellar & Candlelight" look; that serif is retired now
    /// that the cellar shares the family identity. Pair with `.wineChrome()`.
    func wineNavTitle(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                }
            }
    }
}
