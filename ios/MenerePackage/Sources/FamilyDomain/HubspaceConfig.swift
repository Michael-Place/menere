import Foundation

/// Identity + credential for the household's Hubspace/Husky smart **water timer** (hose spigot) via
/// Hubspace's *unofficial* cloud API (P15-C4) — the fleet's **fifth** ecosystem and its **second cloud**
/// integration (after Nest). Decoded from Firestore at `households/{hid}/config/hubspace`.
///
/// ## Cloud + credentials (the private-app posture)
/// Hubspace (Home Depot's platform, built on Afero) has **no official API**. The community reference
/// (`aiohubspace` / jdeath's Home Assistant integration) authenticates against Hubspace's Keycloak with
/// a **username + password** and trades it for OAuth tokens. Michael enters his Hubspace **email +
/// password ONCE** in Settings; we run the login, capture the long-lived **refresh token** + **account
/// id**, and persist *those* — never the password. This mirrors the established decision (Hue app key,
/// Lutron cert, Nest refresh token): a member-gated Firestore config doc is acceptable credential
/// storage for a private family app, so both parents' phones can drive the spigot.
///
/// ## Config/live split (same posture as Hue/Lutron/Nest)
/// The doc holds the *stable* identity — refresh token + account id (+ the email, for the "Connected ·
/// {email}" status line) — while live inventory + state (which spigots, each outlet's open/closed +
/// remaining minutes, battery) come from the Hubspace API. `mock` gates the spigot-less verification
/// path.
///
/// ## Decode-safety
/// A hand-written or mock doc (e.g. `{ mock: true }`) still resolves: every field is optional. An
/// absent doc means "Hubspace never set up" — the House "Water" section simply doesn't render (silent
/// degrade, like Hue/Lutron/Nest).
public struct HubspaceConfig: Codable, Equatable, Sendable {
    /// The long-lived **refresh token** captured when Michael signs into Hubspace. Nil until the login
    /// completes — its presence (or `mock`) is the "connected" gate. `HubspaceClient` exchanges it for
    /// short-lived access tokens as needed.
    public var refreshToken: String?
    /// The Afero **account id** (`api2.afero.net/v1/users/me` → `accountAccess[].account.accountId`),
    /// captured at login. Scopes the devices/state endpoints (`/v1/accounts/{accountId}/…`). Nil until
    /// login completes.
    public var accountId: String?
    /// Michael's Hubspace **email**, kept only for the "Connected · {email}" status line. The
    /// **password is NEVER persisted** — only the refresh token above.
    public var email: String?
    /// When true, `HubspaceClient` serves a stateful fixture spigot instead of calling Hubspace — the
    /// spigot-less verification path (mirrors `NestConfig.mock`). Real households leave this nil/false.
    public var mock: Bool?

    public init(
        refreshToken: String? = nil,
        accountId: String? = nil,
        email: String? = nil,
        mock: Bool? = nil
    ) {
        self.refreshToken = refreshToken
        self.accountId = accountId
        self.email = email
        self.mock = mock
    }

    private enum CodingKeys: String, CodingKey {
        case refreshToken, accountId, email, mock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        mock = try c.decodeIfPresent(Bool.self, forKey: .mock)
    }

    /// True when the client should serve the fixture spigot rather than hit Hubspace.
    public var isMock: Bool { mock == true }

    /// True once login has produced a refresh token + account id (or in mock mode) — the "Connected"
    /// gate for Settings and the House "Water" section.
    public var isConnected: Bool {
        isMock || (refreshToken?.isEmpty == false && accountId?.isEmpty == false)
    }
}
