import Foundation

// Client-surface value types + wire constants for the Hubspace/Husky water-timer integration (P15-C4).
// These describe *live* spigot state read from Hubspace's (unofficial, Afero-backed) cloud API and
// normalized into what the House "Water" section speaks. All Foundation-clean, Sendable, Equatable so
// they flow through TCA state.
//
// Reference: `aioafero` (github.com/Expl0dingBanana/aioafero, successor to the archived `aiohubspace`)
// and jdeath's Home Assistant integration. The exact strings below are taken from that source and its
// `tests/v1/data/water-timer-raw.json` fixture — see the field-by-field notes.

/// Errors from the Hubspace login + API calls (P15-C4). The Water section treats every failure as
/// "hide / show stale" — it never surfaces an error to the user (same degrade-silently contract as
/// Hue/Lutron/Nest).
public enum HubspaceError: Error, Equatable, Sendable {
    /// The config is missing a refresh token / account id, so we can't authenticate.
    case notConfigured
    /// The login *flow* broke before we could even present credentials — we couldn't fetch or parse
    /// the Keycloak login page, or the credential POST returned no usable `code` for a reason other
    /// than a rejected password (network hiccup, or the reference flow drifted). This is NOT a
    /// "wrong password" — it must not be surfaced as one.
    case loginFailed
    /// The Keycloak login page rendered and we posted the credentials, but the auth server rejected
    /// them (non-302, no OTP form) — the email/password really is wrong.
    case invalidCredentials
    /// The account has a second factor (email OTP) enabled; Keycloak returned the OTP form. We can't
    /// complete that headlessly, so we surface it distinctly rather than as a bad password.
    case otpRequired
    /// A token exchange / refresh response was malformed or missing `access_token`.
    case invalidTokenResponse
    /// `users/me` carried no `accountAccess[].account.accountId`.
    case noAccountId
    /// An API call failed after a token refresh + one retry.
    case requestFailed
}

/// The credential captured at the end of a successful Hubspace login — the long-lived **refresh token**
/// plus the Afero **account id** — which the Settings flow persists into `HubspaceConfig`. The password
/// is used only in-flight and is NEVER part of this (or the config).
public struct HubspaceTokens: Equatable, Sendable {
    /// Long-lived Keycloak refresh token (scope includes `offline_access`).
    public let refreshToken: String
    /// The Afero account id (`accountAccess[0].account.accountId`) — scopes every device/state URL.
    public let accountId: String

    public init(refreshToken: String, accountId: String) {
        self.refreshToken = refreshToken
        self.accountId = accountId
    }
}

/// One Hubspace water-timer device (a Husky hose spigot) with its outlets. A water timer typically has
/// **two** independently-controlled outlets, exposed by the API as `functionInstance` `spigot-1` /
/// `spigot-2`.
public struct HubspaceSpigot: Equatable, Sendable, Identifiable {
    /// The metadevice id (`id` in the metadevices JSON) — the `{deviceId}` in the state URL.
    public let id: String
    /// The device's `friendlyName` (e.g. "Front yard spigot").
    public let name: String
    /// The controllable outlets, in `spigot-1`, `spigot-2` order.
    public let outlets: [SpigotOutlet]
    /// Battery charge 0–100 (`battery-level`, `functionInstance` null), nil if the device didn't report
    /// one.
    public let batteryPercent: Int?

    public init(id: String, name: String, outlets: [SpigotOutlet], batteryPercent: Int? = nil) {
        self.id = id
        self.name = name
        self.outlets = outlets
        self.batteryPercent = batteryPercent
    }
}

/// One outlet of a water timer — a valve that's open or closed, optionally counting down a timed run.
public struct SpigotOutlet: Equatable, Sendable, Identifiable {
    /// The API `functionInstance` — `spigot-1` / `spigot-2`. Used as the write target and the id.
    public let instance: String
    /// A human name for the outlet. The metadevices API doesn't reliably expose a per-outlet friendly
    /// name, so the live parse derives a default ("Spigot 1" / "Spigot 2") from the instance; the mock
    /// supplies richer names ("Garden beds" / "Drip line").
    public let name: String
    /// Whether the valve is open (`toggle` == "on").
    public let isOpen: Bool
    /// Minutes left on a timed run (`timer` value, when open and > 0), else nil. **Unit note:** the
    /// reference library doesn't model `timer`, but the sibling `max-on-time` cap is in whole minutes,
    /// so we read/write `timer` as **minutes**. Verified against Michael's live device on first connect.
    public let remainingMinutes: Int?
    /// The device-enforced maximum run length in whole minutes (`max-on-time`), when the device reports
    /// one — the ceiling the House "open for how long" menu bounds its options to. nil = no known cap
    /// (the menu falls back to its default option set).
    public let maxOnMinutes: Int?

    public var id: String { instance }

    public init(instance: String, name: String, isOpen: Bool, remainingMinutes: Int? = nil, maxOnMinutes: Int? = nil) {
        self.instance = instance
        self.name = name
        self.isOpen = isOpen
        self.remainingMinutes = remainingMinutes
        self.maxOnMinutes = maxOnMinutes
    }

    /// The status line for the House row: "Open · 12 min left" / "Open" / "Closed".
    public var statusLine: String {
        guard isOpen else { return "Closed" }
        if let m = remainingMinutes, m > 0 { return "Open · \(m) min left" }
        return "Open"
    }

    /// A copy flipped open/closed with an optional timed-run duration (optimistic UI edits). Preserves
    /// the device's `maxOnMinutes` cap (it's a device property, not a per-run value).
    public func setting(open: Bool, remainingMinutes minutes: Int?) -> SpigotOutlet {
        SpigotOutlet(
            instance: instance,
            name: name,
            isOpen: open,
            remainingMinutes: open ? minutes : nil,
            maxOnMinutes: maxOnMinutes
        )
    }
}

/// The exact Afero `functionClass` / value strings a Hubspace water timer speaks — the single source of
/// truth the transport, the parser, the write-payload builder, the mock, and the P14 agent tools share.
/// Verbatim from `aioafero` + its `water-timer-raw.json` fixture.
public enum HubspaceFunction {
    /// Device-class discriminator in `description.device.deviceClass` — we keep only these.
    public static let waterTimerDeviceClass = "water-timer"

    /// Per-outlet valve on/off. `functionInstance` = `spigot-1` / `spigot-2`; value "on"/"off".
    public static let toggle = "toggle"
    /// Per-outlet run timer (minutes; see `SpigotOutlet.remainingMinutes`). Same instances as `toggle`.
    public static let timer = "timer"
    /// Per-outlet max run guard (minutes) — read only, informs the duration menu ceiling.
    public static let maxOnTime = "max-on-time"
    /// Battery percent; `functionInstance` null.
    public static let batteryLevel = "battery-level"

    /// Category values.
    public static let on = "on"
    public static let off = "off"

    /// The two well-known outlet instances, in display order.
    public static let outletInstances = ["spigot-1", "spigot-2"]

    /// A default display name for an outlet instance ("spigot-1" → "Spigot 1").
    public static func defaultOutletName(_ instance: String) -> String {
        let n = instance.split(separator: "-").last.map(String.init) ?? instance
        return "Spigot \(n)"
    }
}

/// The timed-run durations the House "Water" section offers when opening an outlet. `nil` = "Until
/// turned off" (write `toggle` on with no `timer`). Kept here so the UI and the P14 agent tools share
/// one list.
public enum SpigotDuration {
    /// Offered minute options (the default ceiling when the device reports no `max-on-time`).
    public static let options: [Int] = [5, 10, 15, 30]

    /// The offered minute options bounded by the device's `max-on-time` ceiling (when known): the
    /// defaults at or below the cap, plus the cap itself so the longest legal run is always reachable.
    /// nil cap → the full default set.
    public static func options(maxMinutes: Int?) -> [Int] {
        guard let cap = maxMinutes, cap > 0 else { return options }
        var out = options.filter { $0 <= cap }
        if !out.contains(cap) { out.append(cap) }
        return out.sorted()
    }

    /// A short label ("10 min" / "Until off").
    public static func label(_ minutes: Int?) -> String {
        guard let m = minutes else { return "Until off" }
        return "\(m) min"
    }
}
