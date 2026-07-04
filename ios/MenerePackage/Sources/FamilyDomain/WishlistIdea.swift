import Foundation

/// A "Ideas for Bacán" wishlist entry (P25) — a dead-simple, always-discoverable way for the family
/// to drop "I wish it could X". Captured from the Settings sheet and stored at
/// `households/{hid}/wishlist/{id}`. Member-gated by the existing household rules.
public struct WishlistIdea: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The family member's idea, in their own words.
    public var text: String
    /// Author uid.
    public var uid: String
    /// Author's display name at time of writing (denormalized so the list reads warmly without a join).
    public var authorName: String
    public var at: Date

    public init(
        id: String = UUID().uuidString,
        text: String,
        uid: String,
        authorName: String,
        at: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.uid = uid
        self.authorName = authorName
        self.at = at
    }
}
