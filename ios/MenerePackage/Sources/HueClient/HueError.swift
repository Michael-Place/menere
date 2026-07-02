import Foundation

/// Errors from Hue bridge communication. Ported (trimmed) from NowSpinning's `HueError` —
/// dropped the pairing-specific cases (link-button flow) since this app never pairs.
///
/// Note: the "house" card treats *every* failure as "hide the card / show stale data" — it never
/// surfaces an error to the user. These cases exist for the client's own control flow (e.g. the
/// reachability probe deciding whether to try `rediscover`).
public enum HueError: Error, Equatable, Sendable {
    /// Cloud discovery failed (offline, or no bridge for the id).
    case discoveryFailed
    /// The bridge is not reachable on the LAN (not home, or IP drifted).
    case bridgeUnreachable
    /// The response was malformed / unexpected.
    case invalidResponse
    /// A transport-level error occurred.
    case networkError(String)
    /// The bridge returned a V1 `{"error": {...}}` payload.
    case apiError(Int, String)
}
