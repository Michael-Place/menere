import Foundation

/// A drinking/tasting event — private, per-user. The "what did we try / love?" side of the app and
/// the core retention driver. References a `Wine` (and optionally a specific `Bottle`).
public struct Tasting: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var wineId: String
    public var bottleId: String?
    public var date: Date
    /// Everyday rating, 0.5...5 stars.
    public var ratingStars: Double?
    /// Optional 100-point score for serious notes.
    public var rating100: Int?
    public var note: String?
    /// Optional structured (WSET-style) note.
    public var sat: SATNote?
    public var photoURLs: [URL]
    public var withWhom: String?
    public var occasion: String?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        wineId: String,
        bottleId: String? = nil,
        date: Date = Date(),
        ratingStars: Double? = nil,
        rating100: Int? = nil,
        note: String? = nil,
        sat: SATNote? = nil,
        photoURLs: [URL] = [],
        withWhom: String? = nil,
        occasion: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.wineId = wineId
        self.bottleId = bottleId
        self.date = date
        self.ratingStars = ratingStars
        self.rating100 = rating100
        self.note = note
        self.sat = sat
        self.photoURLs = photoURLs
        self.withWhom = withWhom
        self.occasion = occasion
        self.createdAt = createdAt
    }
}
