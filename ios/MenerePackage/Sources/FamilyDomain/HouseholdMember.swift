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
    /// The member's stable Firestore **document id**. For the household owner this *is* their
    /// Firebase Auth uid; for a **managed persona** (Vale/Famfis/Oliver — a profile with data but
    /// no login yet) it's a synthetic UUID. Every reference to a member (chore assignee, event
    /// assignee, `Document.linkedMemberIds`, `memberStats/{id}`) uses THIS id — so when a persona is
    /// claimed we attach the joiner's uid below while **preserving this id**, keeping all links valid.
    public let id: String
    /// The Firebase Auth uid of the account that **claimed** this member, once someone joins and picks
    /// this persona (P18). `nil` for the owner (whose doc id already *is* their uid) and for managed,
    /// still-unclaimed personas. Decode-safe: existing docs lack this field.
    public var uid: String?
    /// The everyday **display** name shown throughout the app (greetings, leaderboard, roster).
    /// A nickname is perfectly fine here — e.g. "Migueluh". This is the name users see.
    public var name: String
    /// The person's real / legal name (e.g. "Michael"), used for document matching + formal
    /// contexts. Optional: existing member docs that only carry `name` decode fine with this nil.
    /// The Family Brain matches documents against BOTH `name` and `fullName`.
    public var fullName: String?
    public var color: MemberColor
    public var avatarSystemName: String
    public var role: Role
    public var joinedAt: Date

    public init(
        id: String,
        name: String,
        fullName: String? = nil,
        color: MemberColor = .ocean,
        avatarSystemName: String = "person.circle.fill",
        role: Role = .admin,
        joinedAt: Date = Date(),
        uid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.color = color
        self.avatarSystemName = avatarSystemName
        self.role = role
        self.joinedAt = joinedAt
        self.uid = uid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        uid = try c.decodeIfPresent(String.self, forKey: .uid)
        name = try c.decode(String.self, forKey: .name)
        fullName = try c.decodeIfPresent(String.self, forKey: .fullName)
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

    /// True once a real account has claimed this profile (owner or a joiner who picked this persona).
    public var isClaimed: Bool { uid != nil }

    /// A **managed persona** — a profile with data (chores, docs, color) but no login yet
    /// (Vale/Famfis/Oliver). Such a member has no linked `uid` and is *not* the owner-keyed doc.
    /// The owner's doc carries `role == .admin` (its id already is the uid); managed personas were
    /// seeded as `role == .member`. Callers that also have the household in hand should prefer the
    /// authoritative check (`uid == nil && !household.members.contains(id)`); this convenience is for
    /// contexts without that array.
    public var isManaged: Bool { uid == nil && role == .member }

    /// Curated SF Symbol options for the profile avatar picker.
    public static let avatarOptions: [String] = [
        "person.circle.fill", "figure.wave", "star.circle.fill", "heart.circle.fill",
        "leaf.circle.fill", "flame.circle.fill", "bolt.circle.fill", "moon.circle.fill",
        "sun.max.circle.fill", "pawprint.circle.fill", "gamecontroller.fill", "book.circle.fill",
        "music.note", "camera.circle.fill", "bicycle.circle.fill", "airplane.circle.fill",
    ]
}

public extension Sequence where Element == HouseholdMember {
    /// Resolves the **signed-in user's own** member profile from the roster (P18).
    ///
    /// The household **owner** matches by document id (their doc id *is* their uid, and the doc has no
    /// `uid` field). A member who **claimed** a managed persona matches by its linked `uid` (its doc id
    /// stays the original synthetic id, so every id-keyed reference — chores, docs, stats — remains
    /// valid). Managed, still-unclaimed personas never match (no `uid`, synthetic id).
    ///
    /// Use this anywhere the app needs "which member is me?" — never a bare `id == uid`, which would
    /// fail to find a claimed persona.
    func member(forUID uid: String) -> HouseholdMember? {
        first { $0.id == uid || $0.uid == uid }
    }
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
