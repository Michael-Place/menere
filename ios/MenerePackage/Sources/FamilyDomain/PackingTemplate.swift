import Foundation

/// A reusable packing template (P30.5) — a named set of categorized items you can seed a fresh
/// packing list from ("Beach trip", "Weekend away", "Flight with a baby"). Item sets lean into the
/// Place family's real trips (they travel to the DR): Francis's diapers/formula, Oliver's comfort
/// items, sunscreen, the good camera.
///
/// This is pure domain data (no UI, no persistence) so it's shareable + testable. The detail UI
/// materializes a template into `ListItem`s tagged with each entry's `PackingCategory`.
public struct PackingTemplate: Identifiable, Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let category: PackingCategory
        public init(_ title: String, _ category: PackingCategory) {
            self.title = title
            self.category = category
        }
    }

    public let id: String
    public let name: String
    public let icon: String
    /// A one-line, warm description for the picker row.
    public let blurb: String
    public let entries: [Entry]

    public init(id: String, name: String, icon: String, blurb: String, entries: [Entry]) {
        self.id = id
        self.name = name
        self.icon = icon
        self.blurb = blurb
        self.entries = entries
    }

    /// All templates offered in the packing-list template picker.
    public static let all: [PackingTemplate] = [beachTrip, weekendAway, flightWithABaby]

    // MARK: - Beach trip

    public static let beachTrip = PackingTemplate(
        id: "beach-trip",
        name: "Beach trip",
        icon: "beach.umbrella",
        blurb: "Sun, sand, and enough sunscreen for the whole crew.",
        entries: [
            .init("Swimsuits", .clothes),
            .init("Cover-ups", .clothes),
            .init("Sun hats", .clothes),
            .init("Flip-flops", .clothes),
            .init("Light layers for evenings", .clothes),
            .init("Sunscreen (SPF 50)", .toiletries),
            .init("After-sun / aloe", .toiletries),
            .init("Sunglasses", .misc),
            .init("Beach towels", .misc),
            .init("Beach bag", .misc),
            .init("Reusable water bottles", .misc),
            .init("Kids' beach toys", .kidGear),
            .init("Baby sun tent / shade", .kidGear),
            .init("Rash guards for the kids", .kidGear),
            .init("Passports / IDs", .documents),
            .init("Phone chargers", .electronics),
            .init("The good camera", .electronics),
        ]
    )

    // MARK: - Weekend away

    public static let weekendAway = PackingTemplate(
        id: "weekend-away",
        name: "Weekend away",
        icon: "suitcase",
        blurb: "Two nights, one bag — the no-overthinking list.",
        entries: [
            .init("Outfits (2–3)", .clothes),
            .init("Pajamas", .clothes),
            .init("Underwear & socks", .clothes),
            .init("A nicer outfit for dinner", .clothes),
            .init("Toothbrush & toothpaste", .toiletries),
            .init("Deodorant", .toiletries),
            .init("Skincare basics", .toiletries),
            .init("Daily medications", .medications),
            .init("Phone charger", .electronics),
            .init("Snacks for the road", .misc),
            .init("Reusable water bottle", .misc),
        ]
    )

    // MARK: - Flight with a baby

    public static let flightWithABaby = PackingTemplate(
        id: "flight-with-a-baby",
        name: "Flight with a baby",
        icon: "airplane",
        blurb: "Everything to keep Famfis happy at 30,000 feet.",
        entries: [
            // Kid gear — the heart of this one.
            .init("Diapers (1 per hour + extras)", .kidGear),
            .init("Wipes", .kidGear),
            .init("Changing pad", .kidGear),
            .init("Formula / milk", .kidGear),
            .init("Bottles", .kidGear),
            .init("Extra pacifiers", .kidGear),
            .init("Baby carrier", .kidGear),
            .init("Travel stroller", .kidGear),
            .init("Favorite blanket & lovey", .kidGear),
            .init("Quiet toys & board books", .kidGear),
            .init("Baby snacks / puffs", .kidGear),
            .init("Burp cloths", .kidGear),
            // Clothes
            .init("2 outfit changes for baby", .clothes),
            .init("Extra shirt for you (spit-up insurance)", .clothes),
            .init("Baby sweater / socks (cabin is cold)", .clothes),
            // Toiletries & meds
            .init("Infant Tylenol", .medications),
            .init("Gas drops", .medications),
            .init("Diaper cream", .toiletries),
            .init("Hand sanitizer", .toiletries),
            // Documents & electronics
            .init("Baby's passport / birth certificate", .documents),
            .init("Boarding passes", .documents),
            .init("Tablet loaded with shows", .electronics),
            .init("Headphones & chargers", .electronics),
        ]
    )
}
