import Foundation
import FamilyDomain
import HueClient
import LutronClient
import SonosClient
import NestClient
import HubspaceClient
import MerossClient
import HomeKitClient

/// Smart-home actions. Fuzzy name resolution is scoped per ecosystem (rooms, shades, speakers, …).
/// garage OPEN and lock UNLOCK are confirmation-gated (the loop pauses); CLOSE / LOCK run straight.
func houseTools(_ ctx: AgentContext, _ d: AgentDeps) -> [BasicAgentTool] {
    let hid = ctx.hid
    let p = d.persistence

    // MARK: set_room_lights
    let setRoomLights = BasicAgentTool(
        name: "set_room_lights",
        description: "Turn a room's lights on/off and/or set brightness (0–100%). Matches Hue rooms and zones.",
        inputSchema: .object([
            "roomName": .string("Which room/zone."),
            "on": .boolean("Turn on (true) or off (false). Optional."),
            "brightnessPct": .integer("Brightness 0–100. Optional."),
        ], required: ["roomName"])
    ) { input in
        let roomName = input.string("roomName") ?? ""
        guard let cfg = (try? await p.hueConfig(hid)) ?? nil, !cfg.bridges.isEmpty else {
            return AgentToolResult(content: "Lights aren't set up yet.")
        }
        let snaps = await d.hue.readHouse(cfg.bridges)
        let pairs = snaps.flatMap { snap in snap.rooms.map { (snap.bridge, $0) } }
        switch Fuzzy.resolve(roomName, in: pairs, name: { $0.1.name }, aliases: { [$0.1.type] }) {
        case let .matched(pair):
            let on = input.bool("on")
            let bri = input.int("brightnessPct").map { max(1, min(254, Int((Double($0) / 100.0 * 254).rounded()))) }
            do {
                try await d.hue.setGroupState(pair.0, pair.1.id, on ?? (bri != nil ? true : nil), bri)
                var line = pair.1.name
                if let on, !on { line += " off" } else if let pct = input.int("brightnessPct") { line += " \(pct)%" } else { line += " on" }
                return AgentToolResult(
                    content: AgentJSON.object(["room": .string(pair.1.name), "set": .bool(true)]),
                    receipt: AgentReceipt(icon: "lightbulb.fill", line: line)
                )
            } catch {
                return AgentToolResult(content: "Couldn't set \(pair.1.name): \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map { $0.1.name }))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(roomName, available: pairs.map { $0.1.name }))
        }
    }

    // MARK: recall_ritual
    let recallRitual = BasicAgentTool(
        name: "recall_ritual",
        description: "Recall a saved lighting ritual/scene (e.g. bedtime, dinner) — sets its lights and any linked shades.",
        inputSchema: .object([
            "name": .string("Which ritual."),
        ], required: ["name"])
    ) { input in
        let name = input.string("name") ?? ""
        guard let cfg = (try? await p.hueConfig(hid)) ?? nil, !cfg.rituals.isEmpty else {
            return AgentToolResult(content: "No rituals are set up yet.")
        }
        switch Fuzzy.resolve(name, in: cfg.rituals, name: { $0.label }) {
        case let .matched(ritual):
            guard let bridge = cfg.bridges.first(where: { $0.bridgeId == ritual.bridgeId }) else {
                return AgentToolResult(content: "The “\(ritual.label)” ritual's hub isn't reachable.")
            }
            do {
                try await d.hue.recallScene(bridge, ritual.groupId, ritual.sceneId)
                // Fire any linked shade actions best-effort (they're on the Lutron bridge).
                if let shadeActions = ritual.shadeActions, !shadeActions.isEmpty,
                   let lutronCfg = (try? await p.lutronConfig(hid)) ?? nil {
                    for action in shadeActions {
                        try? await d.lutron.setShadeLevel(lutronCfg, action.zoneId, action.level)
                    }
                }
                return AgentToolResult(
                    content: AgentJSON.object(["recalled": .string(ritual.label)]),
                    receipt: AgentReceipt(icon: "sparkles", line: ritual.label)
                )
            } catch {
                return AgentToolResult(content: "Couldn't recall \(ritual.label): \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.label)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(name, available: cfg.rituals.map(\.label)))
        }
    }

    // MARK: set_shade
    let setShade = BasicAgentTool(
        name: "set_shade",
        description: "Set a Lutron shade to a level 0–100% (0 = closed, 100 = open). Matches shade and area names.",
        inputSchema: .object([
            "shadeName": .string("Which shade."),
            "levelPct": .integer("0–100 (0 closed, 100 open)."),
        ], required: ["shadeName", "levelPct"])
    ) { input in
        let shadeName = input.string("shadeName") ?? ""
        guard let level = input.int("levelPct") else { return AgentToolResult(content: "What level (0–100)?") }
        guard let cfg = (try? await p.lutronConfig(hid)) ?? nil, let shades = try? await d.lutron.shades(cfg) else {
            return AgentToolResult(content: "Shades aren't set up yet.")
        }
        switch Fuzzy.resolve(shadeName, in: shades, name: { $0.name }, aliases: { [$0.areaName] }) {
        case let .matched(shade):
            let clamped = max(0, min(100, level))
            do {
                try await d.lutron.setShadeLevel(cfg, shade.zoneId, clamped)
                return AgentToolResult(
                    content: AgentJSON.object(["shade": .string(shade.name), "level": .int(clamped)]),
                    receipt: AgentReceipt(icon: "blinds.horizontal.closed", line: "\(shade.name) \(clamped)%")
                )
            } catch {
                return AgentToolResult(content: "Couldn't set \(shade.name): \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.name)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(shadeName, available: shades.map(\.name)))
        }
    }

    // MARK: sonos
    let sonos = BasicAgentTool(
        name: "sonos",
        description: "Control a Sonos speaker: play, pause, or set_volume (with volumePct 0–100).",
        inputSchema: .object([
            "action": .string("play, pause, or set_volume.", enum: ["play", "pause", "set_volume"]),
            "speakerName": .string("Which speaker/room."),
            "volumePct": .integer("0–100, for set_volume."),
        ], required: ["action", "speakerName"])
    ) { input in
        let action = input.string("action") ?? ""
        let speakerName = input.string("speakerName") ?? ""
        let cfg: SonosConfig? = (try? await p.sonosConfig(hid)) ?? nil
        guard let speakers = try? await d.sonos.discover(cfg), !speakers.isEmpty else {
            return AgentToolResult(content: "No Sonos speakers found.")
        }
        switch Fuzzy.resolve(speakerName, in: speakers, name: { $0.name }) {
        case let .matched(speaker):
            do {
                switch action {
                case "play":
                    try await d.sonos.play(cfg, speaker)
                    return AgentToolResult(content: AgentJSON.object(["playing": .string(speaker.name)]),
                                           receipt: AgentReceipt(icon: "play.fill", line: "Playing \(speaker.name)"))
                case "pause":
                    try await d.sonos.pause(cfg, speaker)
                    return AgentToolResult(content: AgentJSON.object(["paused": .string(speaker.name)]),
                                           receipt: AgentReceipt(icon: "pause.fill", line: "Paused \(speaker.name)"))
                case "set_volume":
                    guard let pct = input.int("volumePct") else { return AgentToolResult(content: "What volume (0–100)?") }
                    let v = SonosVolume.clamp(pct)
                    try await d.sonos.setVolume(cfg, speaker, v)
                    return AgentToolResult(content: AgentJSON.object(["speaker": .string(speaker.name), "volume": .int(v)]),
                                           receipt: AgentReceipt(icon: "speaker.wave.2.fill", line: "\(speaker.name) at \(v)%"))
                default:
                    return AgentToolResult(content: "Unknown action “\(action)”. Use play, pause, or set_volume.")
                }
            } catch {
                return AgentToolResult(content: "Couldn't control \(speaker.name): \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.name)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(speakerName, available: speakers.map(\.name)))
        }
    }

    // MARK: set_thermostat
    let setThermostat = BasicAgentTool(
        name: "set_thermostat",
        description: "Set the thermostat temperature (°F) and/or mode (heat, cool, auto, off). Applies to every thermostat.",
        inputSchema: .object([
            "tempF": .integer("Target temperature in °F. Optional."),
            "mode": .string("heat, cool, auto, or off. Optional.", enum: ["heat", "cool", "auto", "off"]),
        ])
    ) { input in
        guard let cfg = (try? await p.nestConfig(hid)) ?? nil, cfg.isConnected, let thermostats = try? await d.nest.thermostats(cfg), !thermostats.isEmpty else {
            return AgentToolResult(content: "The thermostat isn't set up yet.")
        }
        let mode: NestMode? = input.string("mode").flatMap { raw in
            switch raw.lowercased() {
            case "heat": return .heat
            case "cool": return .cool
            case "auto", "heatcool": return .heatCool
            case "off": return .off
            default: return nil
            }
        }
        let tempF = input.int("tempF").map { NestLimits.clampF($0) }
        if mode == nil && tempF == nil { return AgentToolResult(content: "Give me a temperature and/or a mode.") }

        var acted = 0
        for t in thermostats {
            if let mode { try? await d.nest.setMode(cfg, t.id, mode) }
            if let tempF {
                let effectiveMode = mode ?? t.mode
                let kind: NestSetpointKind = (effectiveMode == .cool) ? .cool : .heat
                let updated = t.settingSetpointF(kind, to: tempF)
                if let sp = updated.commitSetpoint() { try? await d.nest.setTemperatureF(cfg, t.id, sp) }
            }
            acted += 1
        }
        var line = "Thermostat"
        if let tempF { line += " \(tempF)°" }
        if let mode { line += " · \(mode.label)" }
        return AgentToolResult(
            content: AgentJSON.object(["thermostats": .int(acted), "tempF": tempF.map { .int($0) } ?? .null, "mode": mode.map { .string($0.label) } ?? .null]),
            receipt: AgentReceipt(icon: "thermometer.medium", line: line)
        )
    }

    // MARK: set_spigot
    let setSpigot = BasicAgentTool(
        name: "set_spigot",
        description: "Open or close a water-timer spigot, optionally for a number of minutes.",
        inputSchema: .object([
            "outletName": .string("Which spigot/outlet."),
            "open": .boolean("Open (true) or close (false)."),
            "durationMinutes": .integer("Minutes to run when opening. Optional."),
        ], required: ["outletName", "open"])
    ) { input in
        let outletName = input.string("outletName") ?? ""
        guard let open = input.bool("open") else { return AgentToolResult(content: "Open or close?") }
        guard let cfg = (try? await p.hubspaceConfig(hid)) ?? nil, cfg.isConnected, let spigots = try? await d.hubspace.spigots(cfg) else {
            return AgentToolResult(content: "The water timer isn't set up yet.")
        }
        let outlets = spigots.flatMap { s in s.outlets.map { (deviceId: s.id, outlet: $0) } }
        switch Fuzzy.resolve(outletName, in: outlets, name: { $0.outlet.name }) {
        case let .matched(match):
            let duration = open ? input.int("durationMinutes") : nil
            do {
                try await d.hubspace.setSpigot(cfg, match.deviceId, match.outlet.instance, open, duration)
                var line = "\(match.outlet.name) \(open ? "on" : "off")"
                if let duration { line += " for \(duration)m" }
                return AgentToolResult(
                    content: AgentJSON.object(["spigot": .string(match.outlet.name), "open": .bool(open)]),
                    receipt: AgentReceipt(icon: "drop.fill", line: line)
                )
            } catch {
                return AgentToolResult(content: "Couldn't set \(match.outlet.name): \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map { $0.outlet.name }))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(outletName, available: outlets.map { $0.outlet.name }))
        }
    }

    // MARK: garage (open confirmation-gated)
    let garage = BasicAgentTool(
        name: "garage",
        description: "Open or close the garage door. Opening asks for confirmation first.",
        inputSchema: .object([
            "action": .string("open or close.", enum: ["open", "close"]),
        ], required: ["action"]),
        requiresConfirmation: true,
        confirmationPrompt: "Open the garage door?",
        confirmationGate: { input in (input.string("action") ?? "") == "open" }
    ) { input in
        let action = input.string("action") ?? ""
        let open = action == "open"
        // Prefer HomeKit when the Home has a garage opener; else the Meross/Refoss fallback.
        let hkCfg: HomeKitConfig? = (try? await p.homekitConfig(hid)) ?? nil
        let inv = await d.homekit.inventory(hkCfg)
        if let accessory = inv.garageAccessories.first {
            do {
                try await d.homekit.setCharacteristic(hkCfg, accessory.id, .garageDoorOpener, .targetDoorState, .int(open ? 0 : 1))
                return AgentToolResult(content: AgentJSON.object(["garage": .string(open ? "opening" : "closing")]),
                                       receipt: AgentReceipt(icon: open ? "door.garage.open" : "door.garage.closed", line: "Garage \(open ? "opening" : "closing")"))
            } catch {
                return AgentToolResult(content: "Couldn't move the garage: \(error.localizedDescription)")
            }
        }
        if let cfg = (try? await p.merossConfig(hid)) ?? nil, cfg.isConnected, let doors = try? await d.meross.garageState(cfg), let door = doors.first {
            do {
                try await d.meross.setGarage(cfg, door.channel, open)
                return AgentToolResult(content: AgentJSON.object(["garage": .string(open ? "opening" : "closing")]),
                                       receipt: AgentReceipt(icon: open ? "door.garage.open" : "door.garage.closed", line: "Garage \(open ? "opening" : "closing")"))
            } catch {
                return AgentToolResult(content: "Couldn't move the garage: \(error.localizedDescription)")
            }
        }
        return AgentToolResult(content: "No garage opener is set up.")
    }

    // MARK: homekit_lock (unlock confirmation-gated)
    let homekitLock = BasicAgentTool(
        name: "homekit_lock",
        description: "Lock or unlock a HomeKit door lock by name. Unlocking asks for confirmation first.",
        inputSchema: .object([
            "action": .string("lock or unlock.", enum: ["lock", "unlock"]),
            "name": .string("Which lock/door."),
        ], required: ["action", "name"]),
        requiresConfirmation: true,
        confirmationPrompt: "Unlock the door?",
        confirmationGate: { input in (input.string("action") ?? "") == "unlock" }
    ) { input in
        let action = input.string("action") ?? ""
        let name = input.string("name") ?? ""
        let lock = action == "lock"
        let hkCfg: HomeKitConfig? = (try? await p.homekitConfig(hid)) ?? nil
        let inv = await d.homekit.inventory(hkCfg)
        let locks = inv.lockAccessories
        switch Fuzzy.resolve(name, in: locks, name: { $0.name }, aliases: { $0.room.map { [$0] } ?? [] }) {
        case let .matched(accessory):
            do {
                try await d.homekit.setCharacteristic(hkCfg, accessory.id, .lockMechanism, .targetLockState, .int(lock ? 1 : 0))
                return AgentToolResult(content: AgentJSON.object([accessory.name: .string(lock ? "locking" : "unlocking")]),
                                       receipt: AgentReceipt(icon: lock ? "lock.fill" : "lock.open.fill", line: "\(accessory.name) \(lock ? "locking" : "unlocking")"))
            } catch {
                return AgentToolResult(content: "Couldn't move \(accessory.name): \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.name)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(name, available: locks.map(\.name)))
        }
    }

    return [setRoomLights, recallRitual, setShade, sonos, setThermostat, setSpigot, garage, homekitLock]
}
