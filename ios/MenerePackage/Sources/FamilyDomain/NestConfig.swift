import Foundation

/// Identity + credential for the household's Nest thermostat(s) via Google's Smart Device Management
/// (SDM) API (P15-C3), decoded from Firestore at `households/{hid}/config/nest`. This is the fleet's
/// **first cloud integration** — where Hue/Lutron/Sonos talk to the LAN, Nest talks to Google's cloud
/// over OAuth, so the config carries an OAuth identity (a Device Access `projectId` + a GCP OAuth
/// client) and the long-lived **refresh token** minted once Michael links his Google/Nest account.
///
/// ## Config/live split (same posture as Hue/Lutron)
/// The doc holds the *stable* identity — the Device Access project id, the OAuth client id/secret, and
/// the refresh token — while live thermostat inventory + state (ambient temp, humidity, mode,
/// setpoints, room name) come from the SDM API. Config-as-conversation for nothing here; it's pure
/// plumbing.
///
/// ## Why the refresh token lives in the shared config doc
/// SDM authorizes *one Google account* (Michael's, linked to the Nest devices). Both parents' phones
/// must be able to read the thermostat and nudge the setpoint, so the credential MUST be readable by
/// both — it lives in the member-gated config doc (the same "member-gated Firestore is acceptable for
/// a private family app" decision made for the Hue app key and the Lutron client cert), not in
/// per-device Keychain. The refresh token is long-lived (valid until revoked / ~6 months of disuse);
/// `NestClient` trades it for short-lived (1h) access tokens on demand, cached in-memory.
///
/// ## Decode-safety
/// A hand-written or mock doc (e.g. `{ projectId, oauthClientId, mock: true }`) still resolves: the
/// secret + refresh token are optional (nil until the OAuth handshake completes), and `mock` gates the
/// speaker-less… er, thermostat-less verification path. An absent doc means "Nest never set up" — the
/// Climate section simply doesn't render (silent degrade, like Hue/Lutron).
public struct NestConfig: Codable, Equatable, Sendable {
    /// The Device Access **project id** (a GUID) from console.nest.google.com/device-access. Scopes the
    /// SDM `enterprises/{projectId}/devices` endpoint and the OAuth partner-connections URL.
    public var projectId: String
    /// The GCP **OAuth 2.0 client id** (`NNN-xxx.apps.googleusercontent.com`) used for the
    /// authorization-code flow + token refresh.
    public var oauthClientId: String
    /// The GCP OAuth **client secret**, when the client type has one (Web application clients do). Nil
    /// for public/PKCE-only clients. When present it's included in the token exchange/refresh; the flow
    /// also always sends PKCE so a secret-less client still works.
    public var oauthClientSecret: String?
    /// The long-lived **refresh token** captured when Michael links his Google/Nest account. Nil until
    /// the OAuth handshake completes — its presence is the "connected" gate. `NestClient` exchanges it
    /// for access tokens as needed.
    public var refreshToken: String?
    /// When true, `NestClient` serves a stateful fixture thermostat instead of calling Google — the
    /// thermostat-less verification path (mirrors `LutronConfig.mock`). Real households leave this
    /// nil/false.
    public var mock: Bool?

    public init(
        projectId: String,
        oauthClientId: String,
        oauthClientSecret: String? = nil,
        refreshToken: String? = nil,
        mock: Bool? = nil
    ) {
        self.projectId = projectId
        self.oauthClientId = oauthClientId
        self.oauthClientSecret = oauthClientSecret
        self.refreshToken = refreshToken
        self.mock = mock
    }

    private enum CodingKeys: String, CodingKey {
        case projectId, oauthClientId, oauthClientSecret, refreshToken, mock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId) ?? ""
        oauthClientId = try c.decodeIfPresent(String.self, forKey: .oauthClientId) ?? ""
        oauthClientSecret = try c.decodeIfPresent(String.self, forKey: .oauthClientSecret)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
    }

    /// True when the client should serve the fixture thermostat rather than hit Google.
    public var isMock: Bool { mock == true }

    /// True once the OAuth handshake has produced a refresh token (or in mock mode) — the "Connected"
    /// gate for Settings and the Climate section.
    public var isConnected: Bool { isMock || (refreshToken?.isEmpty == false) }

    /// True when the two paste-in identity fields are present — the minimum needed to attempt the OAuth
    /// connect.
    public var hasCredentials: Bool { !projectId.isEmpty && !oauthClientId.isEmpty }
}
