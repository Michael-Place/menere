import SwiftUI
import UIKit

public extension UIColor {
    /// Build a `UIColor` from a 24-bit RGB hex literal (e.g. `0x5A1E2B`). Alpha is always 1.
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }

    // Dynamic light/dark surface + ink tokens as `UIColor`, mirroring the `Color` brand tokens below.
    // Needed for UIKit appearance proxies (e.g. the parchment nav bar in `MenereAppearance`).
    static var parchmentUI: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x1A1614) : UIColor(hex: 0xF5EFE6)
        }
    }
    static var surfaceMenereUI: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x241F1C) : UIColor(hex: 0xFFFFFF)
        }
    }
    static var inkUI: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0xF2EBE2) : UIColor(hex: 0x2A2422)
        }
    }

    // MARK: Family identity ("record-sleeve boldness meets sunroom botanicals")
    // Dynamic light/dark tokens for the NEW family chrome. The wine tokens above are untouched and
    // stay pinned inside the Cellar stack. These `UIColor`s back the `Color` tokens below and the
    // UIKit appearance proxy (`MenereAppearance`), keeping SwiftUI + UIKit chrome in sync.
    static var familyCanvasUI: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x1B1916) : UIColor(hex: 0xFAF7F0)
        }
    }
    static var familySurfaceUI: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x252220) : UIColor(hex: 0xFFFEFA)
        }
    }
    static var bacanGreenUI: UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: 0x5FAE87) : UIColor(hex: 0x2F6D50)
        }
    }
}

public extension Color {
    // Brand reds — identical in both appearances.
    static let wine = Color(uiColor: UIColor(hex: 0x5A1E2B))
    static let oxblood = Color(uiColor: UIColor(hex: 0x7B2D3A))
    static let candleGold = Color(uiColor: UIColor(hex: 0xC8A24B))

    // Surfaces + ink — dynamic light/dark, resolved with no asset catalog. These reuse the matching
    // `UIColor` tokens above so the SwiftUI + UIKit chrome stay perfectly in sync.
    static let parchment = Color(uiColor: .parchmentUI)
    static let surfaceMenere = Color(uiColor: .surfaceMenereUI)
    static let ink = Color(uiColor: .inkUI)
    static let inkSoft = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0xB7AAA0) : UIColor(hex: 0x6B5F58)
    })

    // Drink-window semantics.
    static let drinkNow = Color(uiColor: UIColor(hex: 0x6E8B6A))   // Sage
    static let hold = Color(uiColor: UIColor(hex: 0x5C6F86))       // Slate
    static let past = Color(uiColor: UIColor(hex: 0xA98C8C))       // Faded rose

    // MARK: Family identity — "record-sleeve boldness meets sunroom botanicals"
    // The family-hub palette: warm daylight cream (brighter/fresher than antique parchment),
    // botanical green primary, terracotta + marigold + sky accents. `ink`/`inkSoft` above are shared
    // text colors (they read well on cream too). Wine tokens stay for the Cellar stack.
    static let familyCanvas = Color(uiColor: .familyCanvasUI)      // App background
    static let familySurface = Color(uiColor: .familySurfaceUI)    // Cards, rows
    static let bacanGreen = Color(uiColor: .bacanGreenUI)          // Primary / accent
    static let terracotta = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0xD97A5C) : UIColor(hex: 0xC05A3C)
    })
    static let marigold = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0xEDB44E) : UIColor(hex: 0xE3A02F)
    })
    static let sky = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x6FB1DE) : UIColor(hex: 0x4E93C8)
    })
    // Muted botanical sage — a quieter companion to `bacanGreen` (used for neutral Money bars and
    // the "Money" pinned row). Shares the drink-window sage hue, promoted to a named family token.
    static let sage = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x88A97F) : UIColor(hex: 0x6E8B6A)
    })
}
