import Foundation

// Client-surface value types for the Nest thermostat integration (P15-C3). These describe *live*
// thermostat state read from Google's SDM API and normalized into the units the UI speaks (°F). All
// are Foundation-clean, Sendable, and Equatable so they flow through TCA state.

/// A thermostat operating mode (SDM `sdm.devices.traits.ThermostatMode`). Raw values are the exact SDM
/// wire strings so encode/decode is a straight `rawValue` round-trip.
public enum NestMode: String, Codable, Equatable, Sendable, CaseIterable {
    case heat = "HEAT"
    case cool = "COOL"
    case heatCool = "HEATCOOL"
    case off = "OFF"

    /// A short, warm label for the mode chip.
    public var label: String {
        switch self {
        case .heat: return "Heat"
        case .cool: return "Cool"
        case .heatCool: return "Auto"
        case .off: return "Off"
        }
    }
}

/// A mode-appropriate setpoint change, in °F — what the House stepper commits and the P14 agent tools
/// resolve to. The client maps each case to the matching SDM command (`SetHeat` / `SetCool` /
/// `SetRange`). Kept a small enum so "set the thermostat to 70" is unambiguous about which setpoint(s)
/// move for the device's current mode.
public enum NestSetpoint: Equatable, Sendable {
    /// Heat mode → `ThermostatTemperatureSetpoint.SetHeat`.
    case heat(Int)
    /// Cool mode → `ThermostatTemperatureSetpoint.SetCool`.
    case cool(Int)
    /// Heat·Cool (Auto) mode → `ThermostatTemperatureSetpoint.SetRange`.
    case range(heat: Int, cool: Int)
}

/// One thermostat, normalized from the SDM device JSON. Temperatures arrive in Celsius over the wire
/// and are exposed to the UI in Fahrenheit (the house speaks °F); the raw Celsius stays available for
/// faithful command round-trips.
public struct NestThermostat: Equatable, Sendable, Identifiable {
    /// The full SDM resource name, `enterprises/{projectId}/devices/{deviceId}` — the id used for
    /// `:executeCommand`.
    public let id: String
    /// The room this thermostat sits in, from `parentRelations[].displayName` (e.g. "Downstairs").
    /// Falls back to a custom name or "Thermostat" when no room relation is present.
    public let roomName: String
    /// Ambient temperature in Celsius (`Temperature.ambientTemperatureCelsius`), nil if absent.
    public let ambientCelsius: Double?
    /// Relative humidity 0–100 (`Humidity.ambientHumidityPercent`), nil if absent.
    public let humidityPercent: Double?
    /// Current mode (`ThermostatMode.mode`).
    public let mode: NestMode
    /// Modes this device supports (`ThermostatMode.availableModes`).
    public let availableModes: [NestMode]
    /// Heat setpoint in Celsius (`ThermostatTemperatureSetpoint.heatCelsius`), nil when not applicable.
    public let heatCelsius: Double?
    /// Cool setpoint in Celsius (`ThermostatTemperatureSetpoint.coolCelsius`), nil when not applicable.
    public let coolCelsius: Double?
    /// The HVAC run status (`ThermostatHvac.status`: HEATING / COOLING / OFF), for the UI's live glow.
    public let hvacStatus: String?

    public init(
        id: String,
        roomName: String,
        ambientCelsius: Double?,
        humidityPercent: Double?,
        mode: NestMode,
        availableModes: [NestMode],
        heatCelsius: Double?,
        coolCelsius: Double?,
        hvacStatus: String? = nil
    ) {
        self.id = id
        self.roomName = roomName
        self.ambientCelsius = ambientCelsius
        self.humidityPercent = humidityPercent
        self.mode = mode
        self.availableModes = availableModes
        self.heatCelsius = heatCelsius
        self.coolCelsius = coolCelsius
        self.hvacStatus = hvacStatus
    }

    /// The bare device id (last path component of `name`) — handy for logging / accessibility ids.
    public var deviceId: String { id.split(separator: "/").last.map(String.init) ?? id }

    /// Ambient temperature in °F (one-decimal precision preserved), nil when unknown.
    public var ambientF: Double? { ambientCelsius.map(NestTemp.cToF) }

    /// Humidity as a rounded integer, nil when unknown.
    public var humidityInt: Int? { humidityPercent.map { Int($0.rounded()) } }

    /// Heat setpoint rounded to whole °F, nil when not applicable.
    public var heatSetpointF: Int? { heatCelsius.map(NestTemp.cToFRounded) }
    /// Cool setpoint rounded to whole °F, nil when not applicable.
    public var coolSetpointF: Int? { coolCelsius.map(NestTemp.cToFRounded) }

    /// The single setpoint the stepper edits for the current mode: heat→heat, cool→cool, off→nil.
    /// Heat·Cool (Auto) has two setpoints and is handled separately by the view (no single stepper).
    public var primarySetpointF: Int? {
        switch mode {
        case .heat: return heatSetpointF
        case .cool: return coolSetpointF
        case .heatCool, .off: return nil
        }
    }

    /// The setpoint in °F for a given kind (rounded), nil when that setpoint isn't set.
    public func setpointF(_ kind: NestSetpointKind) -> Int? {
        switch kind {
        case .heat: return heatSetpointF
        case .cool: return coolSetpointF
        }
    }

    /// The `NestSetpoint` to COMMIT for this device's mode, reading its current (optimistically-updated)
    /// setpoints. Heat→SetHeat, Cool→SetCool, Heat·Cool→SetRange, Off→nil.
    public func commitSetpoint() -> NestSetpoint? {
        switch mode {
        case .heat: return heatSetpointF.map(NestSetpoint.heat)
        case .cool: return coolSetpointF.map(NestSetpoint.cool)
        case .heatCool:
            guard let h = heatSetpointF, let c = coolSetpointF else { return nil }
            return .range(heat: h, cool: c)
        case .off: return nil
        }
    }

    /// A copy with one setpoint moved to `f` °F (converted to Celsius for storage). Clamped to
    /// `NestLimits`. Used for optimistic stepper edits.
    public func settingSetpointF(_ kind: NestSetpointKind, to f: Int) -> NestThermostat {
        let c = NestTemp.fToC(Double(NestLimits.clampF(f)))
        switch kind {
        case .heat: return with(heatCelsius: c)
        case .cool: return with(coolCelsius: c)
        }
    }

    /// A copy with a new mode (optimistic mode switch).
    public func settingMode(_ mode: NestMode) -> NestThermostat {
        with(mode: mode)
    }

    /// Copy-with for the fields callers mutate — mode + the two setpoints. Passing nil keeps the
    /// current value (setpoints are never cleared to nil through this path).
    public func with(mode: NestMode? = nil, heatCelsius: Double? = nil, coolCelsius: Double? = nil) -> NestThermostat {
        NestThermostat(
            id: id,
            roomName: roomName,
            ambientCelsius: ambientCelsius,
            humidityPercent: humidityPercent,
            mode: mode ?? self.mode,
            availableModes: availableModes,
            heatCelsius: heatCelsius ?? self.heatCelsius,
            coolCelsius: coolCelsius ?? self.coolCelsius,
            hvacStatus: hvacStatus
        )
    }
}

/// Which of a thermostat's setpoints a stepper edits. Heat·Cool (Auto) exposes both; heat/cool expose
/// their one.
public enum NestSetpointKind: String, Equatable, Sendable {
    case heat, cool
}

/// Sane °F bounds for a home thermostat stepper (also what the P14 agent tools clamp to). Nest itself
/// enforces device limits server-side; this keeps the UI from sending absurd values.
public enum NestLimits {
    public static let minF = 45
    public static let maxF = 95

    public static func clampF(_ f: Int) -> Int { Swift.max(minF, Swift.min(maxF, f)) }
}

/// Celsius↔Fahrenheit conversion for thermostat values, kept pure (no reducer/view) so the P14 agent
/// tools ("set it to 70") resolve a setpoint through the *same* math + rounding the UI uses.
public enum NestTemp {
    /// °C → °F, full precision (e.g. 22.0 → 71.6).
    public static func cToF(_ c: Double) -> Double { c * 9.0 / 5.0 + 32.0 }

    /// °F → °C, full precision (e.g. 70 → 21.111…). What we send to SDM (it stores in Celsius).
    public static func fToC(_ f: Double) -> Double { (f - 32.0) * 5.0 / 9.0 }

    /// °C → nearest whole °F, for displaying a setpoint and for round-trip-stable stepper reads.
    public static func cToFRounded(_ c: Double) -> Int { Int(cToF(c).rounded()) }
}
