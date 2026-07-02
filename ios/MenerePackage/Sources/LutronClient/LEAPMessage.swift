import Foundation

/// The LEAP (Lutron Extensible Application Protocol) wire layer (P15-C1). Faithful to the framing used
/// by the two canonical open implementations:
///   • **pylutron-caseta** (`src/pylutron_caseta/leap.py`, `smartbridge.py`) — Python, the reference.
///   • **lutron-leap-js** (`src/Messages.ts`, `MessageBodyTypes.ts`, `LeapClient.ts`) — TypeScript.
///
/// On the control socket (mutual-TLS, port **8081**) messages are **newline-delimited JSON** — each
/// request serialized to JSON and terminated with `\r\n` (pylutron-caseta writes `text + b"\r\n"`).
/// A request is `{ "CommuniqueType", "Header": { "ClientTag"?, "Url" }, "Body"? }`; responses carry
/// `{ "CommuniqueType", "Header": { "StatusCode"?, "Url"?, "ClientTag"? }, "Body"? }` and are matched
/// back to requests by `ClientTag`.
///
/// The zone command shape (`/zone/{id}/commandprocessor`, `CommandType: GoToLevel`, `Parameter:
/// [{ Type: "Level", Value: n }]`, and the bare `Raise`/`Lower`/`Stop`) is quoted verbatim from
/// pylutron-caseta's `smartbridge.set_value` / `_send_zone_create_request`.

// MARK: - CommuniqueType

/// The LEAP message verbs used by this client. (Lutron defines more; these are the ones we send.)
public enum LEAPCommuniqueType: String, Codable, Sendable {
    case readRequest = "ReadRequest"
    case createRequest = "CreateRequest"
    case subscribeRequest = "SubscribeRequest"
    case updateRequest = "UpdateRequest"
    case readResponse = "ReadResponse"
    case subscribeResponse = "SubscribeResponse"
    case createResponse = "CreateResponse"
    case exceptionResponse = "ExceptionResponse"
}

// MARK: - Requests

/// A LEAP request frame. `Body` is type-erased (`LEAPCommandBody` for zone commands; nil for reads).
public struct LEAPRequest: Encodable, Sendable {
    public var communiqueType: LEAPCommuniqueType
    public var header: Header
    public var body: LEAPCommandBody?

    public struct Header: Encodable, Sendable {
        public var clientTag: String?
        public var url: String

        enum CodingKeys: String, CodingKey {
            case clientTag = "ClientTag"
            case url = "Url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case communiqueType = "CommuniqueType"
        case header = "Header"
        case body = "Body"
    }

    public init(communiqueType: LEAPCommuniqueType, url: String, clientTag: String? = nil, body: LEAPCommandBody? = nil) {
        self.communiqueType = communiqueType
        self.header = Header(clientTag: clientTag, url: url)
        self.body = body
    }

    // MARK: Convenience builders (match the reference implementations)

    /// `ReadRequest` to a resource, e.g. `/device`, `/area`, `/zone/5/status`.
    public static func read(_ url: String, tag: String? = nil) -> LEAPRequest {
        LEAPRequest(communiqueType: .readRequest, url: url, clientTag: tag)
    }

    /// `SubscribeRequest` to a status feed, e.g. `/zone/status`.
    public static func subscribe(_ url: String, tag: String? = nil) -> LEAPRequest {
        LEAPRequest(communiqueType: .subscribeRequest, url: url, clientTag: tag)
    }

    /// `GoToLevel` command on a zone (set an absolute shade level 0–100). Body:
    /// `{"Command":{"CommandType":"GoToLevel","Parameter":[{"Type":"Level","Value":n}]}}`.
    public static func goToLevel(zoneId: String, level: Int, tag: String? = nil) -> LEAPRequest {
        LEAPRequest(
            communiqueType: .createRequest,
            url: "/zone/\(zoneId)/commandprocessor",
            clientTag: tag,
            body: LEAPCommandBody(command: .init(
                commandType: "GoToLevel",
                parameter: [.init(type: "Level", value: LutronLevel.clamp(level))]
            ))
        )
    }

    /// A parameter-free zone command: `Raise` / `Lower` / `Stop`. Body:
    /// `{"Command":{"CommandType":"Raise"}}`.
    public static func zoneCommand(_ commandType: String, zoneId: String, tag: String? = nil) -> LEAPRequest {
        LEAPRequest(
            communiqueType: .createRequest,
            url: "/zone/\(zoneId)/commandprocessor",
            clientTag: tag,
            body: LEAPCommandBody(command: .init(commandType: commandType, parameter: nil))
        )
    }

    public static func raise(zoneId: String, tag: String? = nil) -> LEAPRequest { zoneCommand("Raise", zoneId: zoneId, tag: tag) }
    public static func lower(zoneId: String, tag: String? = nil) -> LEAPRequest { zoneCommand("Lower", zoneId: zoneId, tag: tag) }
    public static func stop(zoneId: String, tag: String? = nil) -> LEAPRequest { zoneCommand("Stop", zoneId: zoneId, tag: tag) }

    /// Serialize to the newline-delimited framing used on the control socket: JSON + `\r\n`.
    public func framed() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(contentsOf: [0x0d, 0x0a])   // \r\n
        return data
    }
}

/// The `Body` of a zone `CreateRequest` — a single `Command`.
public struct LEAPCommandBody: Encodable, Sendable {
    public var command: Command

    public struct Command: Encodable, Sendable {
        public var commandType: String
        public var parameter: [Parameter]?

        public struct Parameter: Encodable, Sendable {
            public var type: String
            public var value: Int
            enum CodingKeys: String, CodingKey {
                case type = "Type"
                case value = "Value"
            }
        }

        enum CodingKeys: String, CodingKey {
            case commandType = "CommandType"
            case parameter = "Parameter"
        }
    }

    enum CodingKeys: String, CodingKey {
        case command = "Command"
    }

    public init(command: Command) {
        self.command = command
    }
}

// MARK: - Responses

/// A decoded LEAP response frame. `Body` is decoded lazily per-endpoint (`decodeBody`), since the
/// shape varies (`Devices`, `Areas`, `ZoneStatus`, `ZoneStatuses`).
public struct LEAPResponse: Decodable, Sendable {
    public var communiqueType: LEAPCommuniqueType?
    public var header: Header
    /// The raw `Body` object, kept as data so callers decode the concrete shape they expect.
    public var bodyData: Data?

    public struct Header: Decodable, Sendable {
        public var statusCode: String?
        public var url: String?
        public var clientTag: String?
        enum CodingKeys: String, CodingKey {
            case statusCode = "StatusCode"
            case url = "Url"
            case clientTag = "ClientTag"
        }
    }

    enum CodingKeys: String, CodingKey {
        case communiqueType = "CommuniqueType"
        case header = "Header"
        case body = "Body"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        communiqueType = try c.decodeIfPresent(LEAPCommuniqueType.self, forKey: .communiqueType)
        header = try c.decodeIfPresent(Header.self, forKey: .header) ?? Header(statusCode: nil, url: nil, clientTag: nil)
        // Re-encode the Body sub-object to Data so the caller can decode its concrete type.
        if c.contains(.body) {
            let raw = try c.decode(LEAPAnyCodable.self, forKey: .body)
            bodyData = try JSONEncoder().encode(raw)
        } else {
            bodyData = nil
        }
    }

    /// The response's status is successful when absent (subscribe pushes) or "2xx".
    public var isSuccessful: Bool {
        guard let code = header.statusCode else { return true }
        return code.hasPrefix("2")
    }

    /// Decode the `Body` into a concrete type.
    public func decodeBody<T: Decodable>(_ type: T.Type) -> T? {
        guard let bodyData else { return nil }
        return try? JSONDecoder().decode(T.self, from: bodyData)
    }

    /// Parse a full newline-delimited buffer into frames. Normalizes CRLF/CR to LF first — Swift folds
    /// `\r\n` into a single grapheme `Character`, so a naive `Character`-based split would never see the
    /// line boundary. We split on unicode scalars instead.
    public static func frames(from buffer: Data) -> [LEAPResponse] {
        guard let text = String(data: buffer, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.unicodeScalars
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { scalars in
                let line = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, let data = line.data(using: .utf8) else { return nil }
                return try? decoder.decode(LEAPResponse.self, from: data)
            }
    }
}

// MARK: - Body shapes (LEAP MessageBodyTypes, trimmed to what shades need)

/// `{"Devices":[…]}` — from `ReadRequest /device` (pylutron-caseta `MultipleDeviceDefinition`).
public struct LEAPDevicesBody: Decodable, Sendable {
    public var devices: [LEAPDevice]
    enum CodingKeys: String, CodingKey { case devices = "Devices" }
}

/// One device definition. Only the fields the shades integration reads are modeled; the rest are
/// ignored by `Decodable`.
public struct LEAPDevice: Decodable, Sendable {
    public var href: String?
    public var name: String?
    public var deviceType: String?
    public var serialNumber: LEAPScalar?
    public var localZones: [LEAPHref]?
    public var associatedArea: LEAPHref?
    enum CodingKeys: String, CodingKey {
        case href, name = "Name", deviceType = "DeviceType"
        case serialNumber = "SerialNumber", localZones = "LocalZones", associatedArea = "AssociatedArea"
    }

    /// The zone id (trailing path component of the first `LocalZones` href), when this device has one.
    public var zoneId: String? {
        guard let z = localZones?.first?.href else { return nil }
        return LEAPHref.lastComponent(z)
    }

    /// The area id (trailing path component of `AssociatedArea.href`).
    public var areaId: String? {
        associatedArea?.href.map(LEAPHref.lastComponent)
    }

    /// True when this device is a shade/blind (matched loosely on `DeviceType`, robust across the
    /// Serena/Triathlon/QsWireless families and RadioRA3's naming).
    public var isShade: Bool {
        guard let t = deviceType?.lowercased() else { return false }
        return t.contains("shade") || t.contains("blind")
    }
}

/// `{"Areas":[…]}` — from `ReadRequest /area`.
public struct LEAPAreasBody: Decodable, Sendable {
    public var areas: [LEAPArea]
    enum CodingKeys: String, CodingKey { case areas = "Areas" }
}

public struct LEAPArea: Decodable, Sendable {
    public var href: String?
    public var name: String?
    enum CodingKeys: String, CodingKey { case href, name = "Name" }
    public var areaId: String? { href.map(LEAPHref.lastComponent) }
}

/// `{"ZoneStatus":{…}}` — from `ReadRequest /zone/{id}/status` (pylutron-caseta `OneZoneStatus`).
public struct LEAPOneZoneStatusBody: Decodable, Sendable {
    public var zoneStatus: LEAPZoneStatus
    enum CodingKeys: String, CodingKey { case zoneStatus = "ZoneStatus" }
}

/// `{"ZoneStatuses":[…]}` — from a `/zone/status` subscription push.
public struct LEAPZoneStatusesBody: Decodable, Sendable {
    public var zoneStatuses: [LEAPZoneStatus]
    enum CodingKeys: String, CodingKey { case zoneStatuses = "ZoneStatuses" }
}

/// A zone's status. `Level` is 0–100 (or -1 / absent when unavailable). `Zone.href` identifies the
/// zone; `href` is the status resource.
public struct LEAPZoneStatus: Decodable, Sendable {
    public var href: String?
    public var level: Int?
    public var zone: LEAPHref?
    enum CodingKeys: String, CodingKey { case href, level = "Level", zone = "Zone" }

    /// The zone id, preferring `Zone.href`, falling back to this status resource's own href.
    public var zoneId: String? {
        if let z = zone?.href { return LEAPHref.lastComponent(z) }
        if let h = href { return LEAPHref.lastComponent(h) }
        return nil
    }
}

/// A `{ "href": "/zone/5" }` reference. LEAP threads resources by href everywhere.
public struct LEAPHref: Decodable, Sendable {
    public var href: String?
    enum CodingKeys: String, CodingKey { case href }

    /// The trailing path component of a LEAP href (`"/zone/5"` → `"5"`).
    public static func lastComponent(_ href: String) -> String {
        href.split(separator: "/").last.map(String.init) ?? href
    }
}

/// A scalar that LEAP sometimes sends as a string and sometimes as a number (e.g. `SerialNumber`).
public enum LEAPScalar: Decodable, Sendable, Equatable {
    case string(String)
    case int(Int)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string((try? c.decode(String.self)) ?? "") }
    }
    public var stringValue: String {
        switch self { case let .string(s): return s; case let .int(i): return String(i) }
    }
}

// MARK: - Type-erased Codable (to shuttle a Body sub-object through Data)

/// Minimal `AnyCodable` used only to re-encode a response's `Body` object so callers can decode the
/// concrete shape. Handles the JSON value kinds LEAP bodies use.
struct LEAPAnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([LEAPAnyCodable].self) { value = a.map(\.value) }
        else if let o = try? c.decode([String: LEAPAnyCodable].self) { value = o.mapValues(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let b as Bool: try c.encode(b)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(LEAPAnyCodable.init))
        case let o as [String: Any]: try c.encode(o.mapValues(LEAPAnyCodable.init))
        default: try c.encodeNil()
        }
    }
}
