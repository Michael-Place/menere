import Foundation

/// Errors from Lutron LEAP communication / pairing (P15-C1). Modeled on `HueError`: the House "shades"
/// section treats *every* read failure as "hide / show stale" — it never surfaces an error. These
/// cases exist for the client's own control flow, and the pairing flow surfaces `buttonNotPressed`
/// (analogous to Hue's `linkButtonNotPressed`) to drive the 30-second countdown.
public enum LutronError: Error, Equatable, Sendable {
    /// mDNS discovery found no `_lutron._tcp` bridge on the LAN.
    case discoveryFailed
    /// The bridge is not reachable on the LAN (not home, or IP drifted).
    case bridgeUnreachable
    /// The LEAP response was malformed / unexpected.
    case invalidResponse
    /// A transport-level (socket/TLS) error occurred.
    case networkError(String)
    /// Pairing: the LAP window is open but the bridge's physical button hasn't been pressed yet — the
    /// pairing flow treats this as "keep waiting", not a hard failure.
    case buttonNotPressed
    /// Pairing: the bridge refused the CSR (401 Unauthorized) or returned no certificate.
    case pairingRejected
    /// Pairing/crypto: couldn't generate the key/CSR or assemble the client identity from the PEMs.
    case credentialError(String)
}
