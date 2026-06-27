import Foundation

/// A physical bottle the user owns (or wants) — private, per-user inventory. References a `Wine` by
/// its canonical id. The "what do we have?" side of the app.
public struct Bottle: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// Canonical `Wine.id` this bottle is an instance of.
    public var wineId: String
    public var purchaseDate: Date?
    public var price: Double?
    public var currency: String?
    public var quantity: Int
    public var store: String?
    public var storageLocation: String?
    /// Drink-window years (e.g. 2026...2032).
    public var drinkFrom: Int?
    public var drinkBy: Int?
    public var status: BottleStatus
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        wineId: String,
        purchaseDate: Date? = nil,
        price: Double? = nil,
        currency: String? = nil,
        quantity: Int = 1,
        store: String? = nil,
        storageLocation: String? = nil,
        drinkFrom: Int? = nil,
        drinkBy: Int? = nil,
        status: BottleStatus = .cellared,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.wineId = wineId
        self.purchaseDate = purchaseDate
        self.price = price
        self.currency = currency
        self.quantity = quantity
        self.store = store
        self.storageLocation = storageLocation
        self.drinkFrom = drinkFrom
        self.drinkBy = drinkBy
        self.status = status
        self.createdAt = createdAt
    }
}

public enum BottleStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case wishlist
    case cellared
    case consumed
    case gifted
}
