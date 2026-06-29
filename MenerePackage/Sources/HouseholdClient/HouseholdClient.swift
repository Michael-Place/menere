import Dependencies
import DependenciesMacros
import FirebaseFunctions
import Foundation

/// Wraps the `joinHousehold` HTTPS callable so features (e.g. SettingsFeature) can join a
/// household by invite code without depending on FirebaseFunctions directly.
@DependencyClient
public struct HouseholdClient: Sendable {
    /// Join a household by invite code. Returns the joined household id (`hid`).
    public var join: @Sendable (_ code: String) async throws -> String
}

public enum HouseholdClientError: Error {
    case invalidResponse
}

extension HouseholdClient: DependencyKey {
    public static let liveValue = HouseholdClient(
        join: { code in
            let callable = Functions.functions(region: "us-central1").httpsCallable("joinHousehold")
            let result = try await callable.call(["code": code])
            guard let hid = (result.data as? [String: Any])?["hid"] as? String else {
                throw HouseholdClientError.invalidResponse
            }
            return hid
        }
    )
}

extension DependencyValues {
    public var household: HouseholdClient {
        get { self[HouseholdClient.self] }
        set { self[HouseholdClient.self] = newValue }
    }
}
