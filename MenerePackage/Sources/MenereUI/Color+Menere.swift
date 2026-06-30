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
}

public extension Color {
    // Brand reds — identical in both appearances.
    static let wine = Color(uiColor: UIColor(hex: 0x5A1E2B))
    static let oxblood = Color(uiColor: UIColor(hex: 0x7B2D3A))
    static let candleGold = Color(uiColor: UIColor(hex: 0xC8A24B))

    // Surfaces + ink — dynamic light/dark, resolved with no asset catalog.
    static let parchment = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x1A1614) : UIColor(hex: 0xF5EFE6)
    })
    static let surfaceMenere = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0x241F1C) : UIColor(hex: 0xFFFFFF)
    })
    static let ink = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0xF2EBE2) : UIColor(hex: 0x2A2422)
    })
    static let inkSoft = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(hex: 0xB7AAA0) : UIColor(hex: 0x6B5F58)
    })

    // Drink-window semantics.
    static let drinkNow = Color(uiColor: UIColor(hex: 0x6E8B6A))   // Sage
    static let hold = Color(uiColor: UIColor(hex: 0x5C6F86))       // Slate
    static let past = Color(uiColor: UIColor(hex: 0xA98C8C))       // Faded rose
}
