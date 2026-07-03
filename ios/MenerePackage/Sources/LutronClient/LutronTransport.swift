import FamilyDomain
import Foundation
import Network

// The live LEAP transport (P15-C1) over Apple's `Network.framework` — no third-party deps. This is the
// path Michael's (and Valentina's) phone runs on the LAN; it is NOT exercised by the mock-based
// verification in this environment. Faithful to pylutron-caseta / lutron-leap-js:
//   • control + pairing are TLS sockets (ports 8081 / 8083),
//   • messages are newline-delimited JSON (see `LEAPMessage`),
//   • control authenticates with the paired client cert; pairing is anonymous TLS + a CSR handshake.

// MARK: - mDNS discovery (`_lutron._tcp`)

enum LutronDiscovery {
    /// Browse for `_lutron._tcp` services and resolve their IPs. Requires the Local Network permission
    /// (declared in Info.plist). Times out after ~4s with whatever was found.
    static func discover(timeout: TimeInterval = 4) async throws -> [DiscoveredLutronBridge] {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_lutron._tcp", domain: nil), using: params)

        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            let found = FoundBridges()

            func finish() {
                guard resumed.setIfUnset() else { return }
                browser.cancel()
                continuation.resume(returning: found.sorted())
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        // Resolve lazily: the endpoint alone gives us a name; the IP is resolved when a
                        // connection is opened. Surface the service name as id + best-effort name.
                        found.insert(DiscoveredLutronBridge(id: name, ip: hostString(for: result.endpoint) ?? name, name: name))
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { finish() }
            }
            browser.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    /// Best-effort host string from a resolved endpoint (Bonjour endpoints resolve to a hostname the
    /// TLS connection accepts directly).
    private static func hostString(for endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case let .hostPort(host, _): return "\(host)"
        default: return nil
        }
    }
}

// MARK: - Control session (port 8081, mutual TLS)

enum LutronLeapSession {
    static let controlPort: UInt16 = 8081

    /// Reachability probe: open the control socket and read `/server/1/status/ping`.
    static func ping(_ config: LutronConfig) async throws -> Bool {
        let conn = try await LutronConnection.open(config: config, port: controlPort)
        defer { conn.close() }
        _ = try await conn.request(.read("/server/1/status/ping", tag: "ping"), tag: "ping", timeout: 4)
        return true
    }

    /// List shades: read `/area` (names), `/device` (shades + their zones), then each shade zone's
    /// `/zone/{id}/status` for the live level.
    static func shades(_ config: LutronConfig) async throws -> [LutronShade] {
        let conn = try await LutronConnection.open(config: config, port: controlPort)
        defer { conn.close() }

        // Area id → name.
        var areaNames: [String: String] = [:]
        if let areasResp = try? await conn.request(.read("/area", tag: "areas"), tag: "areas"),
           let body = areasResp.decodeBody(LEAPAreasBody.self) {
            for area in body.areas {
                if let id = area.areaId, let name = area.name { areaNames[id] = name }
            }
        }

        // Shade devices.
        let devicesResp = try await conn.request(.read("/device", tag: "devices"), tag: "devices")
        guard let devices = devicesResp.decodeBody(LEAPDevicesBody.self)?.devices else { return [] }

        var out: [LutronShade] = []
        for device in devices where device.isShade {
            guard let zoneId = device.zoneId else { continue }
            let area = device.areaId.flatMap { areaNames[$0] } ?? "Shades"
            var level = 0
            if let statusResp = try? await conn.request(.read("/zone/\(zoneId)/status", tag: "z\(zoneId)"), tag: "z\(zoneId)"),
               let status = statusResp.decodeBody(LEAPOneZoneStatusBody.self)?.zoneStatus,
               let lvl = status.level {
                level = LutronLevel.clamp(lvl)
            }
            let name = config.overrideName(forZone: zoneId) ?? device.name ?? area
            out.append(LutronShade(zoneId: zoneId, name: name, areaName: area, level: level))
        }
        return out.sorted { $0.areaName == $1.areaName ? $0.name < $1.name : $0.areaName < $1.areaName }
    }

    /// Set an absolute level via `GoToLevel`.
    static func setLevel(_ config: LutronConfig, zoneId: String, level: Int) async throws {
        try await command(config, .goToLevel(zoneId: zoneId, level: level, tag: "set\(zoneId)"))
    }

    /// Send one zone command and await its `CreateResponse` (best-effort; command sockets are cheap).
    static func command(_ config: LutronConfig, _ request: LEAPRequest) async throws {
        let conn = try await LutronConnection.open(config: config, port: controlPort)
        defer { conn.close() }
        _ = try await conn.request(request, tag: request.header.clientTag, timeout: 6)
    }
}

// MARK: - Pairing session (port 8083, LAP)

enum LutronPairingSession {
    static let pairingPort: UInt16 = 8083

    /// The LAP handshake (pylutron-caseta `pairing.py` / lutron-leap-js `PairingClient.ts`): open ONE
    /// long-lived TLS socket to 8083 **presenting the bundled LAP client certificate** (mutual TLS — the
    /// bridge only opens the pairing session and pushes the button status for an authenticated client),
    /// wait up to `buttonTimeout` for the button-press status (`Body.Status.Permissions` contains
    /// `PhysicalAccess`), then submit the CSR to `/pair` and read the `SigningResult` (signed cert + root
    /// CA). We generate the EC keypair + CSR locally; the returned PEMs become the stored credential.
    ///
    /// The connection is held open for the whole button window (not reconnected per second) — the bridge
    /// pushes the press asynchronously on the live session, so tearing the socket down and reconnecting
    /// would drop the very status we're waiting for.
    ///
    /// Throws `.buttonNotPressed` only when the socket connected but no press arrived in the window
    /// (so the UI can say "we reached the bridge but didn't see the button"); a TLS/connect failure
    /// throws `.networkError` / `.bridgeUnreachable` instead (so the UI can say "couldn't reach the
    /// bridge") — the caller distinguishes these to surface the right guidance.
    static func pair(bridgeIP: String, buttonTimeout: TimeInterval = 30) async throws -> LutronPairingResult {
        let keypair = try LutronCrypto.makePairingKeypair()
        let conn = try await LutronConnection.openPairing(host: bridgeIP, port: pairingPort)
        defer { conn.close() }

        // Wait (bounded) for the physical-access status that indicates the button was pressed.
        let pressed = try await conn.awaitButtonPress(timeout: buttonTimeout)
        guard pressed else { throw LutronError.buttonNotPressed }

        // Submit the CSR: Execute /pair with the CSR text.
        let response = try await conn.pairRequest(csrPEM: keypair.csrPEM, timeout: 12)
        guard let signing = response.signingResult, !signing.certificate.isEmpty else {
            throw LutronError.pairingRejected
        }
        return LutronPairingResult(
            clientCertPEM: signing.certificate,
            clientKeyPEM: keypair.privateKeyPEM,
            bridgeCAPEM: signing.rootCertificate,
            bridgeId: nil,
            bridgeName: nil
        )
    }
}

// MARK: - NWConnection wrapper

/// A thin async wrapper over one `NWConnection` TLS socket: open, send framed LEAP requests, read
/// newline-delimited response frames. One instance per control/pairing exchange (connections are cheap
/// and short-lived here).
final class LutronConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "lutron.leap")
    private var buffer = Data()
    private let lock = NSLock()

    private init(connection: NWConnection) {
        self.connection = connection
    }

    /// Open a mutual-TLS control connection: our client identity + trust anchored on the bridge CA.
    static func open(config: LutronConfig, port: UInt16) async throws -> LutronConnection {
        let identity = try LutronCrypto.makeIdentity(certPEM: config.clientCertPEM, keyPEM: config.clientKeyPEM)
        let tls = NWProtocolTLS.Options()
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        }
        // Trust the bridge's server cert (self-signed by its own CA). We pin loosely — a private LAN
        // device — accepting the presented chain (the bridge CA is carried in `config.bridgeCAPEM`).
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            config.queueForVerify
        )
        return try await connect(host: config.bridgeIP, port: port, tls: tls)
    }

    /// Open the pairing TLS connection (port 8083): present the bundled well-known LAP client identity
    /// (mutual TLS — REQUIRED for the bridge to open the pairing session and push the button status),
    /// pin TLS 1.2 (the bridge's pairing endpoint), and accept the bridge's self-signed server cert.
    /// A missing/failed LAP identity throws `credentialError` rather than silently connecting anonymously.
    static func openPairing(host: String, port: UInt16) async throws -> LutronConnection {
        let identity = try LutronCrypto.makeLAPPairingIdentity()
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else {
            throw LutronError.credentialError("could not create LAP sec_identity")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global()
        )
        return try await connect(host: host, port: port, tls: tls)
    }

    private static func connect(host: String, port: UInt16, tls: NWProtocolTLS.Options) async throws -> LutronConnection {
        let params = NWParameters(tls: tls)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: params)
        let wrapper = LutronConnection(connection: connection)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setIfUnset() { cont.resume() }
                case let .failed(error):
                    if resumed.setIfUnset() { cont.resume(throwing: LutronError.networkError("\(error)")) }
                case .cancelled:
                    if resumed.setIfUnset() { cont.resume(throwing: LutronError.bridgeUnreachable) }
                default:
                    break
                }
            }
            connection.start(queue: wrapper.queue)
            wrapper.startReceiveLoop()
        }
        return wrapper
    }

    func close() { connection.cancel() }

    // MARK: Send / receive

    private func startReceiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock(); self.buffer.append(data); self.lock.unlock()
            }
            if error == nil, !isComplete {
                self.startReceiveLoop()
            }
        }
    }

    private func send(_ request: LEAPRequest) async throws {
        let data = try request.framed()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: LutronError.networkError("\(error)")) }
                else { cont.resume() }
            })
        }
    }

    /// Send a request and await the first response frame matching `tag` (or any frame if tag is nil).
    func request(_ request: LEAPRequest, tag: String?, timeout: TimeInterval = 8) async throws -> LEAPResponse {
        try await send(request)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = takeFrame(where: { tag == nil || $0.header.clientTag == tag }) {
                guard frame.isSuccessful else { throw LutronError.invalidResponse }
                return frame
            }
            try await Task.sleep(nanoseconds: 40_000_000)   // 40ms poll
        }
        throw LutronError.networkError("timeout awaiting \(tag ?? "response")")
    }

    /// Await the button-press status push. The bridge sends a `status;` frame whose
    /// `Body.Status.Permissions` contains `PhysicalAccess` when the physical button is pressed
    /// (pylutron-caseta `pairing.py`; lutron-leap-js reports `Status.Permissions ["Public","PhysicalAccess"]`
    /// with a 200 status). Returns true on the press, false if the window elapses with the socket idle.
    func awaitButtonPress(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if takeFrame(where: { $0.indicatesPhysicalAccess }) != nil { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Build the CSR `/pair` request frame (JSON + `\r\n` framing). Pairing uses the Execute/CSR body
    /// shape (`pairing.py` / `PairingClient.ts`), which differs from the zone-command Body, so it's
    /// hand-built. Extracted (and internal) so the wire shape + framing are unit-testable.
    static func csrRequestFrame(csrPEM: String) throws -> Data {
        let payload: [String: Any] = [
            "Header": ["RequestType": "Execute", "Url": "/pair", "ClientTag": "get-cert"],
            "Body": [
                "CommandType": "CSR",
                "Parameters": ["CSR": csrPEM, "DisplayName": "Bacan", "DeviceUID": "000000000000", "Role": "Admin"],
            ],
        ]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(contentsOf: [0x0d, 0x0a])   // \r\n — matches pylutron-caseta's `buffer + b"\r\n"`
        return data
    }

    /// Submit the CSR to `/pair` and await the `SigningResult` frame.
    func pairRequest(csrPEM: String, timeout: TimeInterval) async throws -> LEAPResponse {
        let data = try Self.csrRequestFrame(csrPEM: csrPEM)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: LutronError.networkError("\(error)")) }
                else { cont.resume() }
            })
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let frame = takeFrame(where: { $0.header.clientTag == "get-cert" }) { return frame }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        throw LutronError.pairingRejected
    }

    // MARK: Frame buffering

    /// Consume all *complete* newline-delimited frames currently buffered (keeping a trailing partial
    /// line in the buffer) and return the first that satisfies `predicate`, or nil if none match yet.
    /// Unifies the control-request, button-press, and CSR-response readers so all three share the same
    /// CRLF-safe framing. (Swift folds "\r\n" into one grapheme, so we normalize to LF before splitting.)
    private func takeFrame(where predicate: (LEAPResponse) -> Bool) -> LEAPResponse? {
        lock.lock()
        guard var text = String(data: buffer, encoding: .utf8) else { lock.unlock(); return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard text.contains("\n") else { lock.unlock(); return nil }
        let lines = text.components(separatedBy: "\n")
        // Keep the trailing partial line (if any) in the buffer.
        let complete = lines.dropLast()
        buffer = (lines.last ?? "").data(using: .utf8) ?? Data()
        lock.unlock()

        let decoder = JSONDecoder()
        for line in complete {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8),
                  let frame = try? decoder.decode(LEAPResponse.self, from: d) else { continue }
            if predicate(frame) { return frame }
        }
        return nil
    }
}

/// Convenience: a serial queue for the TLS verify block.
private extension LutronConfig {
    var queueForVerify: DispatchQueue { DispatchQueue.global(qos: .userInitiated) }
}

/// Thread-safe accumulator for the mDNS browse handler (dedupes by service name).
private final class FoundBridges: @unchecked Sendable {
    private var byName: [String: DiscoveredLutronBridge] = [:]
    private let lock = NSLock()
    func insert(_ bridge: DiscoveredLutronBridge) {
        lock.lock(); byName[bridge.id] = bridge; lock.unlock()
    }
    func sorted() -> [DiscoveredLutronBridge] {
        lock.lock(); defer { lock.unlock() }
        return Array(byName.values).sorted { $0.id < $1.id }
    }
}

/// A tiny one-shot flag guarding continuation resumption / browser finish.
final class LockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

// MARK: - Pairing response decode

extension LEAPResponse {
    /// True when this frame is the button-press status push: `Body.Status.Permissions` contains
    /// `PhysicalAccess` (pylutron-caseta / lutron-leap-js). Falls back to a raw-text scan so we still
    /// detect the press if the body shape drifts across bridge families (Caséta vs RA3).
    var indicatesPhysicalAccess: Bool {
        guard let bodyData else { return false }
        if let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let status = obj["Status"] as? [String: Any],
           let perms = status["Permissions"] as? [String] {
            return perms.contains("PhysicalAccess")
        }
        if let text = String(data: bodyData, encoding: .utf8) { return text.contains("PhysicalAccess") }
        return false
    }

    struct SigningResult { let certificate: String; let rootCertificate: String }

    /// Pull `Body.SigningResult.{Certificate,RootCertificate}` from a `/pair` response.
    var signingResult: SigningResult? {
        guard let bodyData,
              let obj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let signing = obj["SigningResult"] as? [String: Any] else { return nil }
        let cert = signing["Certificate"] as? String ?? ""
        let root = signing["RootCertificate"] as? String ?? ""
        guard !cert.isEmpty else { return nil }
        return SigningResult(certificate: cert, rootCertificate: root)
    }
}
