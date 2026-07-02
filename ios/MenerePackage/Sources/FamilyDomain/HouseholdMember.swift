import Foundation

/// A person in a household, with a display profile (name, color, avatar) and a role.
///
/// Ported/simplified from Fambo's `Member`. Because Menere is adults-only for now, the
/// member id **is** the Firebase Auth uid — every member signs in on their own device, so
/// there's no separate "managed member" id. The `role` enum is retained (defaulting to
/// `.admin` for everyone today) so kid logins can be added later without a model change.
///
/// Persisted at `households/{hid}/members/{uid}`.
public struct HouseholdMember: Codable, Equatable, Identifiable, Sendable {
    /// The member's Firebase Auth uid (also the Firestore document id).
    public let id: String
    public var name: String
    public var color: MemberColor
    public var avatarSystemName: String
    public var role: Role
    public var joinedAt: Date

    public init(
        id: String,
        name: String,
        color: MemberColor = .ocean,
        avatarSystemName: String = "person.circle.fill",
        role: Role = .admin,
        joinedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.avatarSystemName = avatarSystemName
        self.role = role
        self.joinedAt = joinedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(MemberColor.self, forKey: .color) ?? .ocean
        avatarSystemName = try c.decodeIfPresent(String.self, forKey: .avatarSystemName) ?? "person.circle.fill"
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .admin
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt) ?? Date()
    }

    public enum Role: String, Codable, Sendable {
        case admin
        case member
        case child
    }

    /// Curated SF Symbol options for the profile avatar picker.
    public static let avatarOptions: [String] = [
        "person.circle.fill", "figure.wave", "star.circle.fill", "heart.circle.fill",
        "leaf.circle.fill", "flame.circle.fill", "bolt.circle.fill", "moon.circle.fill",
        "sun.max.circle.fill", "pawprint.circle.fill", "gamecontroller.fill", "book.circle.fill",
        "music.note", "camera.circle.fill", "bicycle.circle.fill", "airplane.circle.fill",
    ]
}

/// The fixed per-member color palette. Each member picks a distinct color for at-a-glance
/// attribution across family features (calendar events, chore assignees, etc.).
///
/// Stored as a stable string; RGB values are provided so UI layers can render without a
/// dependency on `MenereUI` (keeps `WineDomain` free of UI imports).
public enum MemberColor: String, Codable, CaseIterable, Sendable {
    case ocean, coral, sage, lavender, sunflower, dusk, slate, ember
    // "The family four" — Michael=botanical, Valentina=terracotta, Oliver=marigold, Famfis=sky.
    // Appended (not reordered) so live Firestore data keeps decoding; picker order is handled by
    // `pickerOrder` below. Their RGB mirrors the C1 identity tokens in MenereUI (bacanGreen /
    // terracotta / marigold / sky) — same shades, replicated here to keep FamilyDomain UI-free.
    case botanical, terracotta, marigold, sky

    /// sRGB components (0...1) for this color.
    public var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .ocean:      return (0.20, 0.52, 0.78)
        case .coral:      return (0.95, 0.45, 0.40)
        case .sage:       return (0.53, 0.68, 0.52)
        case .lavender:   return (0.63, 0.55, 0.82)
        case .sunflower:  return (0.95, 0.75, 0.25)
        case .dusk:       return (0.42, 0.40, 0.60)
        case .slate:      return (0.44, 0.50, 0.56)
        case .ember:      return (0.85, 0.38, 0.24)
        // The family four — hex values match MenereUI's C1 tokens (light-appearance base).
        case .botanical:  return (0.18, 0.43, 0.31)  // bacanGreen  #2F6D50
        case .terracotta: return (0.75, 0.35, 0.24)  // terracotta  #C05A3C
        case .marigold:   return (0.89, 0.63, 0.18)  // marigold    #E3A02F
        case .sky:        return (0.31, 0.58, 0.78)  // sky         #4E93C8
        }
    }

    /// The four owned family colors, first, followed by the original eight — the order the
    /// profile color picker renders. Keeps the enum's declaration order (and thus decoding)
    /// untouched while surfacing the family four up front.
    public static let familyFour: [MemberColor] = [.botanical, .terracotta, .marigold, .sky]

    public static let pickerOrder: [MemberColor] =
        familyFour + allCases.filter { !familyFour.contains($0) }
}
