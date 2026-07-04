import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFirestore
import Foundation
import Sharing
import UserDomain

/// Private, family-only usage telemetry (P25 — the signal loop). Writes light behavioral events to
/// the family's OWN member-gated Firestore at `households/{hid}/analytics/{autoId}` so we can improve
/// the UX from real usage rather than guesses. **No third-party analytics, no PII** beyond the
/// family's own data.
///
/// **Privacy rule:** log event NAMES + light structural context only (screen name, card name, tool
/// name, care kind) — NEVER document contents, message text, or other sensitive payloads.
///
/// The single endpoint is `record(_:_:)`; call sites use the ergonomic ``log(_:_:)`` convenience.
/// Logging is **fire-and-forget**: it resolves the current `hid`/`uid` from `@Shared(.user)`, returns
/// immediately, and does the Firestore write on a detached task with `try?` — it NEVER throws to the
/// UI, never blocks, and no-ops silently when there's no household yet.
@DependencyClient
public struct AnalyticsClient: Sendable {
    /// Underlying sink. Prefer the ``log(_:_:)`` convenience (it supplies the empty-properties default).
    /// Defaulted to a no-op so `testValue`/`previewValue` are silent — features can log freely in tests
    /// without wiring the dependency.
    public var record: @Sendable (_ event: String, _ properties: [String: String]) -> Void = { _, _ in }
}

public extension AnalyticsClient {
    /// Fire-and-forget: record a snake_case `event` with optional light structural `properties`
    /// (e.g. `["tab": "today"]`, `["card": "plants"]`, `["kind": "plant"]`). Returns immediately.
    func log(_ event: String, _ properties: [String: String] = [:]) {
        record(event, properties)
    }
}

extension AnalyticsClient: DependencyKey {
    public static let liveValue = AnalyticsClient(
        record: { event, properties in
            @Shared(.user) var user
            // No household resolved yet → no-op. Resilient by design.
            guard let hid = user?.householdId, !hid.isEmpty, let uid = user?.id else { return }
            let data: [String: Any] = [
                "event": event,
                "properties": properties,
                "uid": uid,
                "at": FieldValue.serverTimestamp(),
            ]
            // Detached + best-effort: never blocks the caller, never throws to the UI.
            Task.detached(priority: .utility) {
                try? await Firestore.firestore()
                    .collection("households").document(hid)
                    .collection("analytics")
                    .addDocument(data: data)
            }
        }
    )
}

public extension DependencyValues {
    var analytics: AnalyticsClient {
        get { self[AnalyticsClient.self] }
        set { self[AnalyticsClient.self] = newValue }
    }
}
