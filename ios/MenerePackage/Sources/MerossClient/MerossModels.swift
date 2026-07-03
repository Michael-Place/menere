import Foundation

// Client-surface value types + wire constants for the Refoss/Meross garage-opener integration (P15-C5).
// These describe *live* door state read over the Meross LAN protocol and normalized into what the House
// "Garage" section speaks. All Foundation-clean, Sendable, Equatable so they flow through TCA state.
//
// Reference: krahabb/meross_lan (the canonical LAN-protocol HA integration) — `merossclient/protocol/
// message.py` (envelope + signing), `.../const.py` (key/method/namespace strings) — cross-checked with
// albertogeniola/MerossIot's garage mixin for the exact GarageDoor.State GET/SET shapes. The field names
// below are verbatim from those sources.

/// Errors from the Meross LAN calls (P15-C5). The Garage section treats every failure as "hide / show
/// stale" — it never surfaces an error to the user (the same degrade-silently contract as the rest of the
/// fleet). Setup surfaces `deviceInfo` throwing as a "couldn't reach the opener" message.
public enum MerossError: Error, Equatable, Sendable {
    /// The config is missing a device IP, so there's nothing to talk to.
    case notConfigured
    /// The HTTP POST to `http://<ip>/config` failed (unreachable, non-2xx, timeout).
    case requestFailed
    /// The device replied but the envelope/payload wasn't the shape we expected (bad JSON, a Meross
    /// `Error` namespace — typically a wrong device key rejected at the sign check).
    case invalidResponse
    /// `Appliance.System.All` carried no `all.system.hardware.uuid`.
    case noDeviceInfo
}

/// Identity of a Meross/Refoss device, read from `Appliance.System.All` on connect. The Settings flow
/// validates the IP + key by fetching this, then persists `uuid` + `name` into `MerossConfig`.
public struct MerossDeviceInfo: Equatable, Sendable {
    /// `all.system.hardware.uuid` — the device uuid, echoed back in the garage `SET` payload.
    public let uuid: String
    /// `all.system.hardware.type` — the device model (e.g. "msg100" / a Refoss opener type).
    public let type: String
    /// A friendly name, when the device reports one (LAN `System.All` usually omits the cloud-set name →
    /// nil, and the setup flow falls back to "Garage").
    public let name: String?
    /// The garage-door channels the device exposes (from `all.digest.garageDoor`), in channel order. A
    /// single-door opener has one channel (0); multi-door units (MSG200) have several.
    public let channels: [GarageDoor]

    public init(uuid: String, type: String, name: String? = nil, channels: [GarageDoor]) {
        self.uuid = uuid
        self.type = type
        self.name = name
        self.channels = channels
    }
}

/// One garage door on a Meross/Refoss opener — a channel that is open or closed. A single-door opener has
/// just channel 0.
public struct GarageDoor: Equatable, Sendable, Identifiable {
    /// The device channel (0-based). The write target and the row id.
    public let channel: Int
    /// A human name for the door. The LAN protocol doesn't reliably expose a per-channel name, so the
    /// live parse derives a default ("Garage" for channel 0, "Garage 2"… otherwise); the mock supplies a
    /// friendly "Garage".
    public let name: String?
    /// Whether the door is open (`open == 1`).
    public let isOpen: Bool

    public var id: Int { channel }

    public init(channel: Int, name: String? = nil, isOpen: Bool) {
        self.channel = channel
        self.name = name
        self.isOpen = isOpen
    }

    /// The display name, falling back to a channel-derived default.
    public var displayName: String { name ?? MerossProtocol.defaultDoorName(channel) }

    /// The resting status line for the House row: "Open" / "Closed" (the transitional "Opening…" /
    /// "Closing…" is a reducer settling state, not a device value).
    public var statusLine: String { isOpen ? "Open" : "Closed" }

    /// A copy flipped open/closed (optimistic UI edits).
    public func setting(open: Bool) -> GarageDoor {
        GarageDoor(channel: channel, name: name, isOpen: open)
    }
}

/// The exact Meross LAN wire constants — the single source of truth the transport, the signer, the
/// parser, the write-payload builder, the mock, and the P14 agent tools share. Verbatim from
/// krahabb/meross_lan's `merossclient` protocol module.
public enum MerossProtocol {
    // Header keys.
    public static let keyHeader = "header"
    public static let keyPayload = "payload"
    public static let keyMessageId = "messageId"
    public static let keyMethod = "method"
    public static let keyNamespace = "namespace"
    public static let keyPayloadVersion = "payloadVersion"
    public static let keyFrom = "from"
    public static let keyTimestamp = "timestamp"
    public static let keySign = "sign"
    public static let keyTriggerSrc = "triggerSrc"

    // Payload keys (garage + system).
    public static let keyState = "state"
    public static let keyChannel = "channel"
    public static let keyOpen = "open"
    public static let keyUUID = "uuid"
    public static let keyAll = "all"
    public static let keySystem = "system"
    public static let keyHardware = "hardware"
    public static let keyDigest = "digest"
    public static let keyGarageDoor = "garageDoor"
    public static let keyType = "type"
    public static let keyError = "error"

    // Methods.
    public static let methodGet = "GET"
    public static let methodSet = "SET"

    // Namespaces.
    public static let namespaceSystemAll = "Appliance.System.All"
    public static let namespaceGarageState = "Appliance.GarageDoor.State"

    // Envelope constants.
    public static let payloadVersion = 1
    /// `header.from` — the reply-to app path. meross_lan uses "/app/…"; a plain "/app/0-0/subscribe"
    /// is accepted by the device and is what we send.
    public static let headerFrom = "/app/0-0/subscribe"
    /// `header.triggerSrc` — the caller identity. Android is what the Meross/Refoss apps send.
    public static let triggerSrc = "Android"

    /// The control endpoint path on every Meross/Refoss device (`http://<ip>/config`).
    public static let configPath = "/config"

    /// A default door name for a channel (channel 0 → "Garage", others → "Garage N+1").
    public static func defaultDoorName(_ channel: Int) -> String {
        channel == 0 ? "Garage" : "Garage \(channel + 1)"
    }
}
