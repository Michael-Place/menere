import SwiftUI

/// A soft 3×3 `MeshGradient` derived from a wine's style — the branded backdrop behind the wineglass
/// placeholder when there's no captured/remote label image. Reds glow oxblood/wine, whites read
/// straw/cream, rosé blushes, sparkling stays pale gold. Palettes are composed entirely from the
/// Menere tokens (no hardcoded hex).
public struct WineTypeGradient: View {
    /// Mirrors `WineDomain.WineType`'s raw values so callers can bridge with
    /// `WineTypeGradient.Kind(rawValue: wine.type.rawValue) ?? .other` without MenereUI depending on
    /// the domain module.
    public enum Kind: String, Sendable {
        case red, white, rose, sparkling, dessert, fortified, other
    }

    let kind: Kind

    public init(type: Kind) {
        self.kind = type
    }

    /// 3×3 evenly-spaced control points.
    private static let points: [SIMD2<Float>] = [
        .init(0, 0), .init(0.5, 0), .init(1, 0),
        .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
        .init(0, 1), .init(0.5, 1), .init(1, 1),
    ]

    /// Nine corner/edge colors, ordered to match `points`. All token-derived.
    private var colors: [Color] {
        switch kind {
        case .red:
            return [
                .oxblood, .wine, .oxblood,
                .wine, .oxblood, .wine,
                .oxblood, .wine, .candleGold.opacity(0.55),
            ]
        case .white:
            return [
                .candleGold.opacity(0.55), .parchment, .candleGold.opacity(0.40),
                .parchment, .candleGold.opacity(0.30), .parchment,
                .candleGold.opacity(0.45), .parchment, .candleGold.opacity(0.50),
            ]
        case .rose:
            return [
                .past, .past.opacity(0.70), .parchment,
                .past.opacity(0.80), .past, .past.opacity(0.60),
                .parchment, .past.opacity(0.70), .candleGold.opacity(0.40),
            ]
        case .sparkling:
            return [
                .parchment, .candleGold.opacity(0.40), .parchment,
                .candleGold.opacity(0.30), .parchment, .candleGold.opacity(0.45),
                .parchment, .candleGold.opacity(0.35), .parchment,
            ]
        case .dessert:
            return [
                .candleGold, .oxblood.opacity(0.70), .candleGold.opacity(0.80),
                .oxblood.opacity(0.60), .candleGold, .oxblood.opacity(0.70),
                .candleGold.opacity(0.80), .oxblood.opacity(0.60), .candleGold,
            ]
        case .fortified:
            return [
                .oxblood, .wine, .candleGold.opacity(0.65),
                .wine, .oxblood, .wine,
                .candleGold.opacity(0.55), .oxblood, .wine,
            ]
        case .other:
            return [
                .parchment, .inkSoft.opacity(0.30), .parchment,
                .inkSoft.opacity(0.25), .parchment, .inkSoft.opacity(0.30),
                .parchment, .inkSoft.opacity(0.20), .parchment,
            ]
        }
    }

    public var body: some View {
        MeshGradient(width: 3, height: 3, points: Self.points, colors: colors)
    }
}

#if DEBUG
#Preview("Wine-type gradients") {
    let kinds: [WineTypeGradient.Kind] = [.red, .white, .rose, .sparkling, .dessert, .fortified, .other]
    return ScrollView {
        VStack(spacing: 12) {
            ForEach(kinds, id: \.rawValue) { kind in
                WineTypeGradient(type: kind)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(Text(kind.rawValue.capitalized).foregroundStyle(.white))
            }
        }
        .padding()
    }
}
#endif
