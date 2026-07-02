import Dependencies
import DependenciesMacros
import FirebaseFunctions
import Foundation

/// Wraps the `processDocument` HTTPS callable — the "Family Brain" AI intake. The household is
/// derived server-side from the caller; we only pass the `docId`. The call is fire-and-forget from
/// the reducer's perspective: on success the library re-fetches and the row upgrades; on failure the
/// row stays pending/failed and the user can re-process it.
@DependencyClient
public struct DocsClient: Sendable {
    /// Kick off (or re-run) AI processing for one document. Returns when the server has written back.
    public var process: @Sendable (_ docId: String) async throws -> Void
}

extension DocsClient: DependencyKey {
    public static let liveValue = DocsClient(
        process: { docId in
            let callable = Functions.functions(region: "us-central1").httpsCallable("processDocument")
            _ = try await callable.call(["docId": docId])
        }
    )
}

extension DependencyValues {
    public var docs: DocsClient {
        get { self[DocsClient.self] }
        set { self[DocsClient.self] = newValue }
    }
}
