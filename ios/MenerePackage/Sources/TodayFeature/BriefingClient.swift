import Dependencies
import DependenciesMacros
import FirebaseFunctions
import Foundation

/// The AI daily briefing shown atop the Today dashboard.
public struct DailyBriefing: Equatable, Sendable {
    public var summary: String
    public var highlights: [String]

    public init(summary: String, highlights: [String]) {
        self.summary = summary
        self.highlights = highlights
    }
}

/// Wraps the `generateDailyBriefing` HTTPS callable. The household is derived server-side from the
/// caller; `force` regenerates (the refresh button) instead of returning the per-day cache.
@DependencyClient
public struct BriefingClient: Sendable {
    public var generate: @Sendable (_ force: Bool) async throws -> DailyBriefing
}

public enum BriefingError: Error, Equatable {
    case invalidResponse
}

extension BriefingClient: DependencyKey {
    public static let liveValue = BriefingClient(
        generate: { force in
            let callable = Functions.functions(region: "us-central1").httpsCallable("generateDailyBriefing")
            let result = try await callable.call(["force": force])
            guard
                let data = result.data as? [String: Any],
                let summary = data["summary"] as? String,
                !summary.isEmpty
            else { throw BriefingError.invalidResponse }
            let highlights = (data["highlights"] as? [String] ?? []).filter { !$0.isEmpty }
            return DailyBriefing(summary: summary, highlights: highlights)
        }
    )
}

extension DependencyValues {
    public var briefing: BriefingClient {
        get { self[BriefingClient.self] }
        set { self[BriefingClient.self] = newValue }
    }
}
