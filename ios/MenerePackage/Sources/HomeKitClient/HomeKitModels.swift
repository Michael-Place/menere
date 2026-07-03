import Foundation

// Client-surface value types for the Apple HomeKit bridge (P15-C7). These are a **snapshot** of the
// live Home — plain Sendable/Equatable value types, NOT the live `HMHome*` reference objects — so they
// flow safely through TCA state across actor boundaries. This file imports **no HomeKit framework**: the
// live adapter (`HomeKitClient.swift`) reads `HMHomeManager` on the main actor and hands classified
// values in here; everything below is pure and unit-testable via the `HK*Source` protocol seams (HomeKit
// classes aren't directly constructible, so tests build fakes that conform to these protocols).

// MARK: - Authorization

/// The app's HomeKit authorization, normalized from `HMHomeManagerAuthorizationStatus`.
public enum HKAuthStatus: Equatable, Sendable {
    /// Not yet asked (or the manager hasn't been created) — Settings shows "Connect to HomeKit".
    case notDetermined
    /// The user granted access — the live Home is readable.
    case authorized
    /// The user denied access — Settings explains + deep-links to the Settings app.
    case denied
    /// Access is restricted (e.g. parental controls) — treated like denied for UI purposes.
    case restricted
}

// MARK: - Service / characteristic / category classification

/// The HomeKit service types this app understands. `other` carries the raw type for anything we don't
/// curate (it still shows in the read-only "All devices" inventory, just not as a control row).
public enum HKServiceType: Equatable, Sendable {
    case garageDoorOpener
    case lockMechanism
    case outlet
    case `switch`
    case lightbulb
    case thermostat
    case temperatureSensor
    case humiditySensor
    case contactSensor
    case other(String)
}

/// The HomeKit characteristic types this app reads/writes. `other` carries the raw type.
public enum HKCharacteristicType: Equatable, Sendable {
    case currentDoorState        // 0 open · 1 closed · 2 opening · 3 closing · 4 stopped
    case targetDoorState         // 0 open · 1 closed
    case currentLockState        // 0 unsecured · 1 secured · 2 jammed · 3 unknown
    case targetLockState         // 0 unsecured · 1 secured
    case powerState              // Bool
    case brightness              // Int 0…100
    case currentTemperature      // Double °C
    case contactState            // 0 detected(closed) · 1 not-detected(open)
    case currentHumidity         // Double %
    case other(String)
}

/// An accessory's HomeKit category — used only for the read-only inventory's display label. Stores the
/// raw `HMAccessoryCategory.categoryType` and prettifies it for display.
public struct HKAccessoryCategory: Equatable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }

    /// A human label: known categories get curated names; anything else is de-camelCased and Title-Cased
    /// (e.g. "garageDoorOpener" → "Garage Door Opener", "windowCovering" → "Window Covering").
    public var displayName: String {
        switch raw {
        case "garageDoorOpener": return "Garage Door Opener"
        case "doorLock": return "Door Lock"
        case "outlet": return "Outlet"
        case "switch": return "Switch"
        case "lightbulb": return "Light"
        case "thermostat": return "Thermostat"
        case "sensor": return "Sensor"
        case "bridge": return "Bridge"
        case "windowCovering": return "Window Covering"
        case "programmableSwitch": return "Programmable Switch"
        case "videoDoorbell": return "Video Doorbell"
        case "ipCamera": return "IP Camera"
        case "fan": return "Fan"
        case "rangeExtender": return "Range Extender"
        case "": return "Accessory"
        default: return HKAccessoryCategory.prettify(raw)
        }
    }

    /// De-camelCase + Title-Case a raw category string, dropping any "HMAccessoryCategoryType" prefix.
    static func prettify(_ raw: String) -> String {
        var s = raw
        if let range = s.range(of: "HMAccessoryCategoryType") { s.removeSubrange(range) }
        guard !s.isEmpty else { return "Accessory" }
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, ch.isUppercase { out.append(" ") }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

// MARK: - Characteristic value (Sendable bridge over HomeKit's `Any?`)

/// A HomeKit characteristic value, narrowed to the four kinds we handle so it can be Sendable/Equatable.
public enum HKCharacteristicValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var boolValue: Bool? {
        switch self {
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .double(d): return d != 0
        case .string: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int(d)
        case let .bool(b): return b ? 1 : 0
        case .string: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        case let .bool(b): return b ? 1 : 0
        case .string: return nil
        }
    }

    /// Bridge a live HomeKit `Any?` into a Sendable case (NSNumber/Bool/Int/Double/String). Unknown → nil.
    public init?(homeKit value: Any?) {
        switch value {
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let n as NSNumber:
            // NSNumber is ambiguous; prefer Bool for the ObjC bool type, else Int for whole values.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if n.doubleValue == n.doubleValue.rounded() { self = .int(n.intValue) }
            else { self = .double(n.doubleValue) }
        default:
            return nil
        }
    }
}

// MARK: - Snapshot value types

/// A characteristic snapshot: its type, its last-read value (nil if unread), and whether it's writable.
public struct HKCharacteristicSnapshot: Equatable, Sendable, Identifiable {
    public let id: String
    public let type: HKCharacteristicType
    public let value: HKCharacteristicValue?
    public let isWritable: Bool

    public init(id: String, type: HKCharacteristicType, value: HKCharacteristicValue?, isWritable: Bool) {
        self.id = id
        self.type = type
        self.value = value
        self.isWritable = isWritable
    }
}

/// A service snapshot: its type, optional name, and characteristics.
public struct HKService: Equatable, Sendable, Identifiable {
    public let id: String
    public let type: HKServiceType
    public let name: String?
    public let characteristics: [HKCharacteristicSnapshot]

    public init(id: String, type: HKServiceType, name: String?, characteristics: [HKCharacteristicSnapshot]) {
        self.id = id
        self.type = type
        self.name = name
        self.characteristics = characteristics
    }

    /// The first characteristic of a given type, if present.
    public func characteristic(_ type: HKCharacteristicType) -> HKCharacteristicSnapshot? {
        characteristics.first { $0.type == type }
    }
}

/// An accessory snapshot: identity, room, category, services, and reachability.
public struct HKAccessory: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let room: String?
    public let category: HKAccessoryCategory
    public let services: [HKService]
    public let isReachable: Bool

    public init(id: String, name: String, room: String?, category: HKAccessoryCategory, services: [HKService], isReachable: Bool) {
        self.id = id
        self.name = name
        self.room = room
        self.category = category
        self.services = services
        self.isReachable = isReachable
    }

    /// The first service of a given type, if the accessory exposes one.
    public func service(_ type: HKServiceType) -> HKService? {
        services.first { $0.type == type }
    }

    /// Whether the accessory exposes any service of the given type.
    public func hasService(_ type: HKServiceType) -> Bool {
        services.contains { $0.type == type }
    }
}

/// The whole-Home snapshot: the (primary) home's name and its accessories.
public struct HKInventory: Equatable, Sendable {
    public var homeName: String?
    public var accessories: [HKAccessory]

    public init(homeName: String? = nil, accessories: [HKAccessory] = []) {
        self.homeName = homeName
        self.accessories = accessories
    }
}

// MARK: - Curation (shared by the reducer's House sections and the unit tests)

public extension HKInventory {
    /// Accessories that expose a garage-door-opener service — these POWER the Garage section (they take
    /// precedence over the Meross fallback). See `HouseReducer` for the precedence rule.
    var garageAccessories: [HKAccessory] {
        accessories.filter { $0.hasService(.garageDoorOpener) }
    }

    /// Door locks → the HomeKit section's lock rows (unlock is confirmation-gated). Excludes garage.
    var lockAccessories: [HKAccessory] {
        accessories.filter { $0.hasService(.lockMechanism) && !$0.hasService(.garageDoorOpener) }
            .sorted { $0.name < $1.name }
    }

    /// Smart plugs / switches → the HomeKit section's toggle rows. **Excludes `lightbulb`** (Hue owns
    /// lights natively; a HomeKit-bridged bulb would double-list) and garage openers.
    var powerAccessories: [HKAccessory] {
        accessories.filter {
            !$0.hasService(.lightbulb)
                && !$0.hasService(.garageDoorOpener)
                && ($0.hasService(.outlet) || $0.hasService(.switch))
        }
        .sorted { $0.name < $1.name }
    }

    /// Read-only sensors (temperature / contact) → the HomeKit section's sensor rows.
    var sensorAccessories: [HKAccessory] {
        accessories.filter {
            !$0.hasService(.lightbulb)
                && ($0.hasService(.temperatureSensor) || $0.hasService(.contactSensor))
                && !$0.hasService(.lockMechanism)
                && !$0.hasService(.outlet) && !$0.hasService(.switch)
        }
        .sorted { $0.name < $1.name }
    }

    /// True when the HomeKit **control** section has anything to show (locks/plugs/sensors) — the garage
    /// has its own section and lightbulbs are excluded, so a lights-only Home shows no control section.
    var hasControllableAccessories: Bool {
        !lockAccessories.isEmpty || !powerAccessories.isEmpty || !sensorAccessories.isEmpty
    }
}

public extension HKAccessory {
    /// A garage door's open/closed reading from its `currentDoorState` (0 == fully open). Any non-closed
    /// state (opening/closing/stopped/open) reads as "open" for the row status.
    var garageIsOpen: Bool? {
        guard let state = service(.garageDoorOpener)?.characteristic(.currentDoorState)?.value?.intValue
        else { return nil }
        return state != 1   // 1 == fully closed; everything else is "open-ish"
    }

    /// A lock's secured/locked reading from its `currentLockState` (1 == secured/locked).
    var lockIsLocked: Bool? {
        guard let state = service(.lockMechanism)?.characteristic(.currentLockState)?.value?.intValue
        else { return nil }
        return state == 1
    }

    /// A plug/switch's on/off reading from its `powerState`.
    var powerIsOn: Bool? {
        let svc = service(.outlet) ?? service(.switch)
        return svc?.characteristic(.powerState)?.value?.boolValue
    }

    /// A temperature sensor's reading, converted °C → °F for display.
    var temperatureF: Double? {
        guard let c = service(.temperatureSensor)?.characteristic(.currentTemperature)?.value?.doubleValue
        else { return nil }
        return c * 9 / 5 + 32
    }

    /// A contact sensor's reading (true == contact closed / e.g. door shut). 0 == detected(closed).
    var contactIsClosed: Bool? {
        guard let state = service(.contactSensor)?.characteristic(.contactState)?.value?.intValue
        else { return nil }
        return state == 0
    }
}

// MARK: - Protocol seams (for pure mapping + unit tests)

/// A source of a characteristic — the live adapter conforms an `HMCharacteristic`; tests conform a fake.
public protocol HKCharacteristicSource {
    var idRaw: String { get }
    var type: HKCharacteristicType { get }
    var value: HKCharacteristicValue? { get }
    var isWritable: Bool { get }
}

/// A source of a service — the live adapter conforms an `HMService`; tests conform a fake.
public protocol HKServiceSource {
    var idRaw: String { get }
    var type: HKServiceType { get }
    var nameRaw: String? { get }
    var characteristicSources: [any HKCharacteristicSource] { get }
}

/// A source of an accessory — the live adapter conforms an `HMAccessory`; tests conform a fake.
public protocol HKAccessorySource {
    var idRaw: String { get }
    var nameRaw: String { get }
    var roomRaw: String? { get }
    var categoryRaw: String { get }
    var serviceSources: [any HKServiceSource] { get }
    var isReachableRaw: Bool { get }
}

/// The pure snapshot assembler — maps protocol sources into the Sendable value types. The live coordinator
/// calls this on the main actor with real `HM*` adapters; tests call it with fakes. This is the "mapping"
/// the P15-C7 unit tests lock (name/room/category/services/characteristics/writability all flow through).
public enum HomeKitSnapshot {
    public static func inventory(homeName: String?, accessories: [any HKAccessorySource]) -> HKInventory {
        HKInventory(homeName: homeName, accessories: accessories.map(accessory(from:)))
    }

    public static func accessory(from src: any HKAccessorySource) -> HKAccessory {
        HKAccessory(
            id: src.idRaw,
            name: src.nameRaw,
            room: src.roomRaw,
            category: HKAccessoryCategory(src.categoryRaw),
            services: src.serviceSources.map(service(from:)),
            isReachable: src.isReachableRaw
        )
    }

    public static func service(from src: any HKServiceSource) -> HKService {
        HKService(
            id: src.idRaw,
            type: src.type,
            name: src.nameRaw,
            characteristics: src.characteristicSources.map {
                HKCharacteristicSnapshot(id: $0.idRaw, type: $0.type, value: $0.value, isWritable: $0.isWritable)
            }
        )
    }
}
