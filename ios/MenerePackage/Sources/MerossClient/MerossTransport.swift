import CryptoKit
import FamilyDomain
import Foundation

// The live Meross LAN transport (P15-C5): a signed JSON envelope POSTed to `http://<device-ip>/config`.
// This is the LOCAL path Michael's (and Valentina's) phone runs on the home network — there is NO cloud
// and NO account round-trip. It is NOT exercised by the mock-based verification.
//
// Everything the wire touches is pure and unit-tested: the envelope builder, the MD5 signer, the
// System.All / GarageDoor.State parsers, and the SET payload builder. The only impure edge is the HTTP
// POST, behind an injectable `MerossHTTPClient` seam.

/// A thin injectable HTTP seam so the envelope/signing/parsing logic is unit-testable without a device on
/// the LAN.
struct MerossHTTPClient: Sendable {
    var perform: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live: MerossHTTPClient = {
        // Short timeouts: a LAN device answers in well under a second, and the Garage section degrades
        // silently — we never want a dead IP to hang the House screen.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        return MerossHTTPClient(
            perform: { req in
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { throw MerossError.requestFailed }
                return (data, http)
            }
        )
    }()
}

// MARK: - Envelope + signing

/// Pure Meross envelope construction + signing (unit-tested against a known MD5 vector). The signature is
/// `MD5(messageId + key + timestamp)` per krahabb/meross_lan `compute_message_signature`.
public enum MerossEnvelope {
    /// The Meross message signature: `md5(messageId + key + String(timestamp))` as a lowercase hex string.
    public static func sign(messageId: String, key: String, timestamp: Int) -> String {
        let digest = Insecure.MD5.hash(data: Data("\(messageId)\(key)\(timestamp)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh 32-char lowercase-hex message id (16 random bytes), matching meross_lan's
    /// `"%032x" % int.from_bytes(os.urandom(16))`.
    public static func generateMessageId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Build a full signed envelope dict for a namespace + method + payload. `timestamp` and `messageId`
    /// are injectable so the builder is deterministic under test.
    public static func envelope(
        method: String,
        namespace: String,
        payload: [String: Any],
        key: String,
        messageId: String,
        timestamp: Int
    ) -> [String: Any] {
        let header: [String: Any] = [
            MerossProtocol.keyMessageId: messageId,
            MerossProtocol.keyNamespace: namespace,
            MerossProtocol.keyMethod: method,
            MerossProtocol.keyPayloadVersion: MerossProtocol.payloadVersion,
            MerossProtocol.keyFrom: MerossProtocol.headerFrom,
            MerossProtocol.keyTriggerSrc: MerossProtocol.triggerSrc,
            MerossProtocol.keyTimestamp: timestamp,
            MerossProtocol.keySign: sign(messageId: messageId, key: key, timestamp: timestamp),
        ]
        return [MerossProtocol.keyHeader: header, MerossProtocol.keyPayload: payload]
    }

    /// The `Appliance.GarageDoor.State` SET payload to open/close one channel:
    /// `{"state": {"channel": N, "open": 0/1, "uuid": <device uuid>}}` (verbatim from MerossIot's garage
    /// mixin). `uuid` may be empty when the device didn't report one — the device tolerates it.
    public static func garageSetPayload(channel: Int, open: Bool, uuid: String) -> [String: Any] {
        [MerossProtocol.keyState: [
            MerossProtocol.keyChannel: channel,
            MerossProtocol.keyOpen: open ? 1 : 0,
            MerossProtocol.keyUUID: uuid,
        ]]
    }
}

// MARK: - Response parsers

/// Pure parsing of Meross responses (unit-tested against fixtures).
public enum MerossParse {
    /// A generic response envelope check: reject a Meross `Error` namespace (what a bad device key looks
    /// like), and return `payload`.
    static func payload(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MerossError.invalidResponse
        }
        if let header = root[MerossProtocol.keyHeader] as? [String: Any],
           let ns = header[MerossProtocol.keyNamespace] as? String,
           ns.contains(MerossProtocol.keyError) || ns.hasSuffix(".Error") {
            throw MerossError.invalidResponse
        }
        guard let payload = root[MerossProtocol.keyPayload] as? [String: Any] else {
            throw MerossError.invalidResponse
        }
        return payload
    }

    /// Parse an `Appliance.System.All` response into device info (uuid, type, name?, channels).
    public static func deviceInfo(_ data: Data) throws -> MerossDeviceInfo {
        let payload = try payload(data)
        let all = payload[MerossProtocol.keyAll] as? [String: Any] ?? [:]
        let system = all[MerossProtocol.keySystem] as? [String: Any] ?? [:]
        let hardware = system[MerossProtocol.keyHardware] as? [String: Any] ?? [:]
        guard let uuid = hardware[MerossProtocol.keyUUID] as? String, !uuid.isEmpty else {
            throw MerossError.noDeviceInfo
        }
        let type = hardware[MerossProtocol.keyType] as? String ?? "meross"
        // LAN System.All rarely carries a friendly name; keep it optional.
        let name = (system["online"] as? [String: Any])?["devName"] as? String
            ?? hardware["devName"] as? String

        // Channels come from the digest's garageDoor list.
        let digest = all[MerossProtocol.keyDigest] as? [String: Any] ?? [:]
        let doors = digest[MerossProtocol.keyGarageDoor] as? [[String: Any]] ?? []
        let channels = doors.map { door in
            GarageDoor(
                channel: (door[MerossProtocol.keyChannel] as? Int) ?? 0,
                name: nil,
                isOpen: openValue(door[MerossProtocol.keyOpen])
            )
        }.sorted { $0.channel < $1.channel }
        return MerossDeviceInfo(uuid: uuid, type: type, name: name, channels: channels)
    }

    /// Parse an `Appliance.GarageDoor.State` GET/PUSH response into `[GarageDoor]`. `payload["state"]` is
    /// a list of `{channel, open}` on multi-channel devices, or a single dict on some single-door units —
    /// both are handled.
    public static func garageState(_ data: Data) throws -> [GarageDoor] {
        let payload = try payload(data)
        let states: [[String: Any]]
        if let list = payload[MerossProtocol.keyState] as? [[String: Any]] {
            states = list
        } else if let one = payload[MerossProtocol.keyState] as? [String: Any] {
            states = [one]
        } else {
            throw MerossError.invalidResponse
        }
        return states.map { door in
            GarageDoor(
                channel: (door[MerossProtocol.keyChannel] as? Int) ?? 0,
                name: nil,
                isOpen: openValue(door[MerossProtocol.keyOpen])
            )
        }.sorted { $0.channel < $1.channel }
    }

    /// Coerce a Meross `open` value (Int 0/1, or occasionally a bool/string) to a Swift Bool.
    static func openValue(_ any: Any?) -> Bool {
        if let i = any as? Int { return i == 1 }
        if let b = any as? Bool { return b }
        if let s = any as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }
}

// MARK: - Session

/// A LAN session for one household config — builds signed envelopes, POSTs them to the device, and parses
/// the replies. Stateless beyond the injected HTTP seam + a `now`/`messageId` provider for determinism.
struct MerossSession: Sendable {
    var http: MerossHTTPClient = .live
    var now: @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    var messageId: @Sendable () -> String = { MerossEnvelope.generateMessageId() }

    /// POST a signed envelope to `http://<ip>/config` and return the raw response data.
    private func post(ip: String, key: String, method: String, namespace: String, payload: [String: Any]) async throws -> Data {
        guard let url = URL(string: "http://\(ip)\(MerossProtocol.configPath)") else { throw MerossError.notConfigured }
        let envelope = MerossEnvelope.envelope(
            method: method, namespace: namespace, payload: payload,
            key: key, messageId: messageId(), timestamp: now()
        )
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: envelope)
        let (data, resp) = try await http.perform(req)
        guard (200..<300).contains(resp.statusCode) else { throw MerossError.requestFailed }
        return data
    }

    /// `Appliance.System.All` GET → device identity + channels.
    func deviceInfo(ip: String, key: String) async throws -> MerossDeviceInfo {
        let data = try await post(ip: ip, key: key, method: MerossProtocol.methodGet,
                                  namespace: MerossProtocol.namespaceSystemAll, payload: [:])
        return try MerossParse.deviceInfo(data)
    }

    /// `Appliance.GarageDoor.State` GET → current door states.
    func garageState(config: MerossConfig) async throws -> [GarageDoor] {
        guard let ip = config.deviceIP, !ip.isEmpty else { throw MerossError.notConfigured }
        let data = try await post(ip: ip, key: config.deviceKey ?? "", method: MerossProtocol.methodGet,
                                  namespace: MerossProtocol.namespaceGarageState, payload: [:])
        return try MerossParse.garageState(data)
    }

    /// `Appliance.GarageDoor.State` SET → open/close one channel.
    func setGarage(config: MerossConfig, channel: Int, open: Bool) async throws {
        guard let ip = config.deviceIP, !ip.isEmpty else { throw MerossError.notConfigured }
        let payload = MerossEnvelope.garageSetPayload(channel: channel, open: open, uuid: config.uuid ?? "")
        _ = try await post(ip: ip, key: config.deviceKey ?? "", method: MerossProtocol.methodSet,
                          namespace: MerossProtocol.namespaceGarageState, payload: payload)
    }
}
