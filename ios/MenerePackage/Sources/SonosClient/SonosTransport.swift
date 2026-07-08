import Foundation
import Network

// The live Sonos transport (P15-C2): Bonjour discovery + UPnP/SOAP control over the LAN. This is the
// path Michael's (and Valentina's) phone runs at home; it is NOT exercised by the mock-based
// verification. LAN-first by design — NO cloud, NO OAuth, NO SSDP (Apple's multicast entitlement is
// deliberately avoided). Modern Sonos players advertise via Bonjour as `_sonos._tcp`, so discovery
// uses `NWBrowser` mDNS exactly like `LutronTransport` did; control is plain-HTTP SOAP on port 1400.

/// Errors from Sonos discovery / control (P15-C2). Modeled on `LutronError`: the House "Speakers"
/// section treats every failure as "hide / show stale" — it never surfaces an error to the user.
public enum SonosError: Error, Equatable, Sendable {
    /// mDNS discovery found no `_sonos._tcp` player on the LAN (not home, or no Sonos).
    case discoveryFailed
    /// A player was found but its UPnP control call failed (unreachable / bad response).
    case controlFailed
    /// The SOAP response was malformed / unexpected.
    case invalidResponse
}

enum SonosTransport {
    static let port: UInt16 = 1400

    // MARK: - Discovery (`_sonos._tcp` → resolve → ZoneGroupTopology)

    /// Discover the household's Sonos players. Browse `_sonos._tcp`, resolve endpoints to IPs, then ask
    /// ANY reachable player for the full `GetZoneGroupState` — one topology read yields every player,
    /// its room name, its group, and the coordinator per group. Falls back to a per-player
    /// device-description read (each a solo group) if topology is unavailable.
    static func discover(browseTimeout: TimeInterval = 3) async throws -> [SonosSpeaker] {
        let endpoints = try await browse(timeout: browseTimeout)
        guard !endpoints.isEmpty else { throw SonosError.discoveryFailed }

        // Resolve endpoints to IPs (in parallel), keep the reachable ones.
        var ips: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for endpoint in endpoints {
                group.addTask { await resolveIP(endpoint) }
            }
            for await ip in group where ip != nil { ips.append(ip!) }
        }
        let uniqueIPs = Array(Set(ips))
        guard !uniqueIPs.isEmpty else { throw SonosError.discoveryFailed }

        // One topology read from any reachable player describes the whole system.
        for ip in uniqueIPs {
            if let xml = try? await soapCall(ip: ip, service: .zoneGroupTopology, action: "GetZoneGroupState", args: []) {
                let speakers = SonosSOAP.parseZoneGroups(xml)
                if !speakers.isEmpty { return speakers }
            }
        }

        // Degraded fallback: describe each resolved player as its own solo group.
        var solo: [SonosSpeaker] = []
        for ip in uniqueIPs {
            if let s = try? await describe(ip: ip) { solo.append(s) }
        }
        guard !solo.isEmpty else { throw SonosError.discoveryFailed }
        return solo
    }

    /// Browse `_sonos._tcp` and collect the service endpoints (deduped by name). Mirrors
    /// `LutronDiscovery.discover`.
    private static func browse(timeout: TimeInterval) async throws -> [NWEndpoint] {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_sonos._tcp", domain: nil), using: params)

        return await withCheckedContinuation { continuation in
            let resumed = SonosLockedFlag()
            let found = FoundEndpoints()

            @Sendable func finish() {
                guard resumed.setIfUnset() else { return }
                browser.cancel()
                continuation.resume(returning: found.all())
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        found.insert(name: name, endpoint: result.endpoint)
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

    /// Resolve a Bonjour service endpoint to a LAN IP by opening a short TCP connection and reading the
    /// resolved remote host. Returns nil if it can't connect in ~3s.
    private static func resolveIP(_ endpoint: NWEndpoint) async -> String? {
        let connection = NWConnection(to: endpoint, using: .tcp)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let resumed = SonosLockedFlag()
            @Sendable func finish(_ ip: String?) {
                guard resumed.setIfUnset() else { return }
                connection.cancel()
                cont.resume(returning: ip)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                        finish(hostIP(host))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    /// A LAN IP string from an `NWEndpoint.Host`, stripping any IPv6 zone id.
    private static func hostIP(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case let .ipv4(addr): return "\(addr)".components(separatedBy: "%").first
        case let .ipv6(addr): return "\(addr)".components(separatedBy: "%").first
        case let .name(name, _): return name
        @unknown default: return nil
        }
    }

    /// Read one player's `/xml/device_description.xml` for its `roomName` (degraded solo fallback).
    private static func describe(ip: String) async throws -> SonosSpeaker {
        let url = URL(string: "http://\(ip):\(port)/xml/device_description.xml")!
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "GET"
        let (data, _) = try await URLSession.shared.data(for: req)
        let xml = String(decoding: data, as: UTF8.self)
        let room = SonosSOAP.firstValue(of: "roomName", in: xml).map(SonosSOAP.unescape) ?? "Sonos"
        let udn = SonosSOAP.firstValue(of: "UDN", in: xml)?.replacingOccurrences(of: "uuid:", with: "") ?? ip
        return SonosSpeaker(id: udn, name: room, ip: ip, groupId: nil, isCoordinator: true)
    }

    // MARK: - Control verbs (address the group coordinator)

    static func nowPlaying(_ speaker: SonosSpeaker) async throws -> SonosNowPlaying {
        async let transportXML = soapCall(ip: speaker.ip, service: .avTransport, action: "GetTransportInfo", args: [("InstanceID", "0")])
        async let positionXML = soapCall(ip: speaker.ip, service: .avTransport, action: "GetPositionInfo", args: [("InstanceID", "0")])
        let state = SonosSOAP.parseTransportState(try await transportXML)
        let position = try await positionXML
        return SonosSOAP.parseNowPlaying(positionInfoXML: position, transportState: state, speakerIP: speaker.ip)
    }

    static func play(_ speaker: SonosSpeaker) async throws {
        _ = try await soapCall(ip: speaker.ip, service: .avTransport, action: "Play", args: [("InstanceID", "0"), ("Speed", "1")])
    }

    static func pause(_ speaker: SonosSpeaker) async throws {
        _ = try await soapCall(ip: speaker.ip, service: .avTransport, action: "Pause", args: [("InstanceID", "0")])
    }

    static func next(_ speaker: SonosSpeaker) async throws {
        _ = try await soapCall(ip: speaker.ip, service: .avTransport, action: "Next", args: [("InstanceID", "0")])
    }

    static func previous(_ speaker: SonosSpeaker) async throws {
        _ = try await soapCall(ip: speaker.ip, service: .avTransport, action: "Previous", args: [("InstanceID", "0")])
    }

    static func volume(_ speaker: SonosSpeaker) async throws -> Int {
        let xml = try await soapCall(ip: speaker.ip, service: .renderingControl, action: "GetVolume", args: [("InstanceID", "0"), ("Channel", "Master")])
        guard let v = SonosSOAP.parseVolume(xml) else { throw SonosError.invalidResponse }
        return SonosVolume.clamp(v)
    }

    static func setVolume(_ speaker: SonosSpeaker, _ volume: Int) async throws {
        _ = try await soapCall(
            ip: speaker.ip, service: .renderingControl, action: "SetVolume",
            args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(SonosVolume.clamp(volume)))]
        )
    }

    static func mute(_ speaker: SonosSpeaker) async throws -> Bool {
        let xml = try await soapCall(ip: speaker.ip, service: .renderingControl, action: "GetMute", args: [("InstanceID", "0"), ("Channel", "Master")])
        guard let muted = SonosSOAP.parseMute(xml) else { throw SonosError.invalidResponse }
        return muted
    }

    static func setMute(_ speaker: SonosSpeaker, _ muted: Bool) async throws {
        _ = try await soapCall(
            ip: speaker.ip, service: .renderingControl, action: "SetMute",
            args: [("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0")]
        )
    }

    // MARK: - SOAP over HTTP (port 1400)

    /// POST a SOAP action to a player and return the response body XML. Plain HTTP on the LAN — allowed
    /// by `NSAllowsLocalNetworking` (see App/Info.plist); no TLS, no auth.
    static func soapCall(ip: String, service: SonosService, action: String, args: [(String, String)]) async throws -> String {
        guard let url = URL(string: "http://\(ip):\(port)\(service.controlPath)") else { throw SonosError.controlFailed }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue(SonosSOAP.soapAction(service, action), forHTTPHeaderField: "SOAPACTION")
        req.httpBody = SonosSOAP.envelope(action: action, service: service, args: args).data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SonosError.controlFailed
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Small concurrency helpers (module-local)

/// A one-shot flag guarding continuation resumption / browser finish (mirrors `LockedFlag`).
final class SonosLockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func setIfUnset() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

/// Thread-safe accumulator for the mDNS browse handler (dedupes by service name).
private final class FoundEndpoints: @unchecked Sendable {
    private var byName: [String: NWEndpoint] = [:]
    private let lock = NSLock()
    func insert(name: String, endpoint: NWEndpoint) {
        lock.lock(); byName[name] = endpoint; lock.unlock()
    }
    func all() -> [NWEndpoint] {
        lock.lock(); defer { lock.unlock() }
        return Array(byName.values)
    }
}
