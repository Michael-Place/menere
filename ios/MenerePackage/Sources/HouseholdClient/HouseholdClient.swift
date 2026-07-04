import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// A managed persona a joiner can **claim** on the "Which family member are you?" step (P18).
/// Surfaced by `joinHousehold` (server-side, since a prospective joiner can't yet read the
/// members subcollection through the security rules). `id` is the member's stable Firestore doc id.
public struct ClaimablePersona: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let fullName: String?
    public let color: MemberColor
    public let avatarSystemName: String

    public init(id: String, name: String, fullName: String?, color: MemberColor, avatarSystemName: String) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.color = color
        self.avatarSystemName = avatarSystemName
    }
}

/// The outcome of a `joinHousehold` call (P18). The first (no-claim) call joins the household and
/// returns any `unclaimed` managed personas so the client can offer the claim picker; a follow-up
/// call carrying `claimMemberId` re-runs to attach the persona.
public struct JoinOutcome: Equatable, Sendable {
    /// The joined household id.
    public let hid: String
    /// The managed personas still available to claim (empty when there are none, or after a claim).
    public let unclaimed: [ClaimablePersona]

    public init(hid: String, unclaimed: [ClaimablePersona]) {
        self.hid = hid
        self.unclaimed = unclaimed
    }
}

/// Wraps the `joinHousehold` HTTPS callable so features (e.g. SettingsFeature) can join a
/// household by invite code — and claim an existing managed persona (P18) — without depending on
/// FirebaseFunctions directly.
@DependencyClient
public struct HouseholdClient: Sendable {
    /// Join a household by invite code. Pass `claimMemberId` to attach the caller's account to an
    /// existing managed persona (preserving its doc id + every link); pass `nil` to just join and
    /// discover the claimable personas. Returns the joined `hid` + the still-`unclaimed` personas.
    public var join: @Sendable (_ code: String, _ claimMemberId: String?) async throws -> JoinOutcome
}

public enum HouseholdClientError: Error {
    case invalidResponse
}

extension HouseholdClient: DependencyKey {
    public static let liveValue = HouseholdClient(
        join: { code, claimMemberId in
            let callable = Functions.functions(region: "us-central1").httpsCallable("joinHousehold")
            var payload: [String: Any] = ["code": code]
            if let claimMemberId { payload["claimMemberId"] = claimMemberId }
            let result = try await callable.call(payload)
            guard let data = result.data as? [String: Any],
                  let hid = data["hid"] as? String else {
                throw HouseholdClientError.invalidResponse
            }
            let rawUnclaimed = (data["unclaimedMembers"] as? [[String: Any]]) ?? []
            let unclaimed: [ClaimablePersona] = rawUnclaimed.compactMap { dict in
                guard let id = dict["id"] as? String, let name = dict["name"] as? String else { return nil }
                let color = (dict["color"] as? String).flatMap(MemberColor.init(rawValue:)) ?? .ocean
                let avatar = dict["avatarSystemName"] as? String ?? "person.circle.fill"
                return ClaimablePersona(
                    id: id, name: name, fullName: dict["fullName"] as? String,
                    color: color, avatarSystemName: avatar
                )
            }
            return JoinOutcome(hid: hid, unclaimed: unclaimed)
        }
    )
}

extension DependencyValues {
    public var household: HouseholdClient {
        get { self[HouseholdClient.self] }
        set { self[HouseholdClient.self] = newValue }
    }
}
