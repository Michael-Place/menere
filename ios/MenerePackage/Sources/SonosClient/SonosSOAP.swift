import Foundation

/// The Sonos UPnP/SOAP wire layer (P15-C2). Faithful to the two canonical open implementations:
///   • **SoCo** (`soco/core.py`, `soco/services.py`, `soco/groups.py`) — Python, the reference.
///   • **node-sonos** (`lib/services/Service.js`, `lib/sonos.js`) — JavaScript.
///
/// Sonos players answer UPnP/SOAP over plain HTTP on **port 1400**. Each action is an HTTP `POST` to a
/// service `controlURL` with a `SOAPACTION` header and an `s:Envelope` body; responses are XML with the
/// action's return args (and, for now-playing/topology, an *escaped* XML document nested inside a single
/// arg — `TrackMetaData` carries DIDL-Lite, `ZoneGroupState` carries the topology). No authentication.
enum SonosService {
    case avTransport
    case renderingControl
    case zoneGroupTopology

    /// The UPnP service type URN (used verbatim in the `SOAPACTION` header and the `xmlns:u` namespace).
    var serviceType: String {
        switch self {
        case .avTransport: return "urn:schemas-upnp-org:service:AVTransport:1"
        case .renderingControl: return "urn:schemas-upnp-org:service:RenderingControl:1"
        case .zoneGroupTopology: return "urn:schemas-upnp-org:service:ZoneGroupTopology:1"
        }
    }

    /// The HTTP control path on port 1400 (node-sonos `TRANSPORT_ENDPOINT` / `RENDERING_ENDPOINT`).
    var controlPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        }
    }
}

enum SonosSOAP {
    /// The `SOAPACTION` header value: `"{serviceType}#{action}"` (quotes included, per UPnP).
    static func soapAction(_ service: SonosService, _ action: String) -> String {
        "\"\(service.serviceType)#\(action)\""
    }

    /// Build the SOAP request envelope. `args` are ordered `(name, value)` UPnP arguments — e.g.
    /// `[("InstanceID","0"),("Speed","1")]` for `Play`. Mirrors node-sonos `Helpers.CreateSoapEnvelop`.
    static func envelope(action: String, service: SonosService, args: [(String, String)]) -> String {
        let body = args.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body>"
            + "<u:\(action) xmlns:u=\"\(service.serviceType)\">\(body)</u:\(action)>"
            + "</s:Body></s:Envelope>"
    }

    // MARK: - Response parsing

    /// AVTransport `GetTransportInfo` → `CurrentTransportState` folded to the UI's three states.
    /// `TRANSITIONING` and anything unknown read as `.stopped` (the row shows "Idle").
    static func parseTransportState(_ xml: String) -> SonosNowPlaying.PlaybackState {
        switch firstValue(of: "CurrentTransportState", in: xml) {
        case "PLAYING": return .playing
        case "PAUSED_PLAYBACK": return .paused
        default: return .stopped
        }
    }

    /// RenderingControl `GetVolume` → `CurrentVolume` (0–100).
    static func parseVolume(_ xml: String) -> Int? {
        firstValue(of: "CurrentVolume", in: xml).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// AVTransport `GetPositionInfo` → now-playing. `TrackMetaData` holds an *escaped* DIDL-Lite doc;
    /// unescape it, then pull `dc:title` / `dc:creator` / `upnp:albumArtURI` (album art resolved to an
    /// absolute URL on the speaker).
    static func parseNowPlaying(
        positionInfoXML: String, transportState state: SonosNowPlaying.PlaybackState, speakerIP: String
    ) -> SonosNowPlaying {
        let meta = firstValue(of: "TrackMetaData", in: positionInfoXML).map(unescape) ?? ""
        let title = firstValue(of: "dc:title", in: meta).map(unescape)?.nilIfBlank
        let artist = firstValue(of: "dc:creator", in: meta).map(unescape)?.nilIfBlank
        let art = firstValue(of: "upnp:albumArtURI", in: meta).map(unescape)?.nilIfBlank
        let url = art.flatMap { resolveAlbumArt($0, speakerIP: speakerIP) }
        return SonosNowPlaying(title: title, artist: artist, albumArtURL: url, state: state)
    }

    /// Resolve a DIDL `albumArtURI` (usually a `/getaa?…` path relative to the speaker) to an absolute
    /// URL. Absolute `http(s)` URIs pass through unchanged.
    static func resolveAlbumArt(_ raw: String, speakerIP: String) -> URL? {
        if raw.lowercased().hasPrefix("http") { return URL(string: raw) }
        let path = raw.hasPrefix("/") ? raw : "/" + raw
        return URL(string: "http://\(speakerIP):1400\(path)")
    }

    /// ZoneGroupTopology `GetZoneGroupState` → the household's players with their grouping. The response
    /// arg `ZoneGroupState` is an *escaped* topology doc: `<ZoneGroup Coordinator="…" ID="…">` wrapping
    /// `<ZoneGroupMember UUID="…" Location="http://ip:1400/…" ZoneName="…"/>` rows. Invisible members
    /// (BOOST / bridge) are skipped. Groups don't nest, so we split on the group open-tag boundary.
    static func parseZoneGroups(_ responseXML: String) -> [SonosSpeaker] {
        let inner = firstValue(of: "ZoneGroupState", in: responseXML).map(unescape) ?? responseXML
        var speakers: [SonosSpeaker] = []
        for chunk in inner.components(separatedBy: "<ZoneGroup ").dropFirst() {
            let scope = chunk.components(separatedBy: "</ZoneGroup>").first ?? chunk
            let openTag = scope.components(separatedBy: ">").first ?? scope
            let coordinatorUID = attribute("Coordinator", inAttributes: openTag)
            let groupID = attribute("ID", inAttributes: openTag)
            for memberTag in scope.components(separatedBy: "<ZoneGroupMember ").dropFirst().map({
                $0.components(separatedBy: ">").first ?? $0
            }) {
                guard attribute("Invisible", inAttributes: memberTag) != "1",
                      let uid = attribute("UUID", inAttributes: memberTag),
                      let zone = attribute("ZoneName", inAttributes: memberTag),
                      let location = attribute("Location", inAttributes: memberTag),
                      let ip = URLComponents(string: location)?.host else { continue }
                speakers.append(SonosSpeaker(
                    id: uid, name: unescape(zone), ip: ip,
                    groupId: groupID, isCoordinator: uid == coordinatorUID
                ))
            }
        }
        var seen = Set<String>()
        return speakers.filter { seen.insert($0.id).inserted }
    }

    // MARK: - Tiny XML helpers (no XMLParser — the shapes are flat + well-known)

    /// The text content of the first `<tag …>…</tag>` (attributes on the open tag tolerated).
    static func firstValue(of tag: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)") else { return nil }
        guard let gt = xml[open.upperBound...].firstIndex(of: ">") else { return nil }
        let contentStart = xml.index(after: gt)
        guard let close = xml.range(of: "</\(tag)>", range: contentStart..<xml.endIndex) else { return nil }
        return String(xml[contentStart..<close.lowerBound])
    }

    /// The value of `name="…"` within an element's attribute text. A leading space is prepended so the
    /// match requires a word boundary — this stops `attribute("ID", …)` from matching inside `UUID="…"`.
    static func attribute(_ name: String, inAttributes text: String) -> String? {
        let padded = " " + text
        guard let r = padded.range(of: " \(name)=\"") else { return nil }
        let rest = padded[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    /// XML-escape an argument value (for outgoing envelopes).
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Unescape XML entities (for the nested escaped docs Sonos returns).
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x2f;", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
