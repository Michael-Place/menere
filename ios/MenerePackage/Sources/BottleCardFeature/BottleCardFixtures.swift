#if DEBUG
import Foundation
import UIKit
import WineDomain

/// Fixture wines for previews + unit tests. DEBUG-only.
public enum BottleCardFixtures {
    /// Identity-only wine (region + grapes known from the scan, no enrichment yet) used to preview the
    /// `isResolving: true` progressive-reveal state — enrichment rows render as shimmer.
    public static let resolvingIdentity = Wine(
        producer: "Château Margaux",
        name: "Grand Vin",
        vintage: 2015,
        region: Region(country: "France", region: "Bordeaux", appellation: "Margaux"),
        grapes: ["Cabernet Sauvignon", "Merlot"],
        type: .other
    )

    /// A synthesized label image for previews of the captured-image path (no bundled asset / no
    /// IdentifyClient dependency needed). Renders a simple gradient + caption.
    public static var sampleLabelImageData: Data {
        let size = CGSize(width: 600, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.26, green: 0.05, blue: 0.12, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.13, blue: 0.20, alpha: 1).cgColor]
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            let text = "SAMPLE LABEL" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 44),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
            ]
            let textSize = text.size(withAttributes: attrs)
            text.draw(
                at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
                withAttributes: attrs
            )
        }
        return image.pngData() ?? Data()
    }

    /// A richly-enriched wine with mixed provenance: authoritative (Verified), AI estimate, scanned.
    public static let richlyEnriched = Wine(
        producer: "Château Margaux",
        name: "Grand Vin",
        vintage: 2015,
        region: Region(
            country: "France",
            region: "Bordeaux",
            subregion: "Médoc",
            appellation: "Margaux"
        ),
        grapes: ["Cabernet Sauvignon", "Merlot", "Petit Verdot", "Cabernet Franc"],
        type: .red,
        abv: 13.5,
        enrichment: Enrichment(
            summary: "A profound, perfumed Margaux with silky tannins, cassis, violet and graphite "
                + "notes, and a long, mineral finish.",
            drinkingWindow: "2025–2050",
            foodPairings: ["Roast lamb", "Aged hard cheese", "Beef tenderloin", "Wild mushrooms"],
            producerNote: "A wine of finesse and power; the 2015 is among the great recent vintages.",
            provenance: [
                "region": Provenance(source: .wikidata, confidence: 0.95),
                "grapes": Provenance(source: .wikidata, confidence: 0.9),
                "type": Provenance(source: .openFoodFacts, confidence: 0.92),
                "abv": Provenance(source: .ttbCola, confidence: 0.98),
                "summary": Provenance(source: .llm, confidence: 0.7),
                "drinkingWindow": Provenance(source: .llm, confidence: 0.6),
                "foodPairings": Provenance(source: .llm, confidence: 0.65),
                "producerNote": Provenance(source: .llm, confidence: 0.6),
                "producer": Provenance(source: .ocr, confidence: 0.8),
                "name": Provenance(source: .ocr, confidence: 0.75),
                "vintage": Provenance(source: .ocr, confidence: 0.85),
            ]
        )
    )

    /// An identity-only wine: no enrichment at all (and therefore no badges).
    public static let identityOnly = Wine(
        producer: "Domaine Anonyme",
        name: nil,
        vintage: 2021
    )

    /// A partially-enriched wine: a couple of verified facts + one AI estimate, no producer note.
    public static let partiallyEnriched = Wine(
        producer: "Ridge Vineyards",
        name: "Monte Bello",
        vintage: 2018,
        region: Region(country: "USA", region: "California", subregion: "Santa Cruz Mountains"),
        grapes: ["Cabernet Sauvignon", "Merlot"],
        type: .red,
        abv: 13.8,
        enrichment: Enrichment(
            summary: "Structured and ageworthy, with dark fruit, cedar and a savory backbone.",
            drinkingWindow: nil,
            foodPairings: ["Grilled steak", "Braised short ribs"],
            producerNote: nil,
            provenance: [
                "region": Provenance(source: .openFoodFacts, confidence: 0.9),
                "abv": Provenance(source: .ttbCola, confidence: 0.97),
                "grapes": Provenance(source: .ocr, confidence: 0.7),
                "summary": Provenance(source: .llm, confidence: 0.68),
                "foodPairings": Provenance(source: .user, confidence: 1.0),
            ]
        )
    )
}
#endif
