import ComposableArchitecture
import FamilyDomain
import Foundation
import HomeKitClient
import HueClient
import LutronClient
import NestClient
import SonosClient
import SwiftUI

// MARK: - House view mode (Rooms / Devices)
//
// Michael's smart-home layout call: the House screen can organize itself BY ROOM ("Rooms") or BY TYPE
// ("Devices"). Devices mode is the untouched Wave-1 product-grouped layout (Hue rooms, shades, speakers,
// climate, water, garage, HomeKit — each its own section). Rooms mode is a RE-LAYOUT of the exact same
// rows: every device is bucketed by the room it lives in, so a room card shows that room's lights +
// shade + climate + speaker together, and room-less devices (water, garage, HomeKit without a room)
// collect in a "Whole house" section at the bottom.

/// Which axis the House screen groups devices on. Persisted in `@AppStorage("house.viewMode")`.
public enum HouseViewMode: String, CaseIterable, Sendable {
    /// Group every device by the room it lives in (room cards + a "Whole house" bucket).
    case rooms
    /// The Wave-1 product-grouped layout (one section per subsystem). The safe default = current behavior.
    case devices
}

// MARK: - Room grouping model

/// A single Hue room within a named room bucket, carrying the bridge it belongs to so the existing
/// `roomRow` (with its toggle + Hue room-detail navigation) re-renders unchanged.
struct HueRoomRef: Equatable, Identifiable {
    let bridgeId: String
    let room: HueRoom
    var id: String { "\(bridgeId)/\(room.id)" }
}

/// One room's worth of devices, merged case-insensitively across every subsystem (so a Hue
/// "Living Room" + a Lutron "Living room" + a Sonos "Living Room" collapse into ONE card — the
/// acknowledged de-dupe TODO). The card reuses the SAME W1 rows (`roomRow` / `shadeRow` /
/// `thermostatRow` / `speakerRow` / HomeKit lock/plug/sensor rows) — this is a re-layout, not new controls.
struct HouseRoomGroup: Identifiable, Equatable {
    /// The normalized (trimmed + lowercased) merge key.
    let key: String
    /// The first-seen original spelling — what the card header shows.
    let displayName: String
    var hueRooms: [HueRoomRef] = []
    var shades: [LutronShade] = []
    var thermostats: [NestThermostat] = []
    var speakers: [SonosGroup] = []
    var locks: [HKAccessory] = []
    var plugs: [HKAccessory] = []
    var sensors: [HKAccessory] = []

    var id: String { key }

    /// How many discrete devices this room holds — the primary room-ordering key (busiest room first).
    var deviceCount: Int {
        hueRooms.count + shades.count + thermostats.count + speakers.count
            + locks.count + plugs.count + sensors.count
    }
}

extension HouseReducer.State {
    /// Normalize a raw room name for merge (trim + case-fold). Returns nil when there's nothing left —
    /// a room-less device (empty / whitespace name), which the caller routes to "Whole house".
    private func normalizedRoomKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    /// The room cards for Rooms mode: every REACHABLE device bucketed by its room, merged case-
    /// insensitively across subsystems, ordered by device count (busiest first) then name. Only `.ok`
    /// sections contribute (loading/offline sections still render their own placeholder, unchanged); a
    /// device with no room name is excluded here and surfaces in `wholeHouse…` instead.
    var roomGroups: [HouseRoomGroup] {
        var map: [String: HouseRoomGroup] = [:]
        var order: [String] = []

        /// Ensure a bucket exists for `raw`'s room and return its key (nil = room-less → skip).
        func ensure(_ raw: String) -> String? {
            guard let key = normalizedRoomKey(raw) else { return nil }
            if map[key] == nil {
                map[key] = HouseRoomGroup(key: key, displayName: raw.trimmingCharacters(in: .whitespacesAndNewlines))
                order.append(key)
            }
            return key
        }

        // Hue — real rooms only (Zones are cross-room groupings that would double-count lights, so they
        // stay a Devices-mode concept; every zone light is still reachable via its room card).
        if hueStatus == .ok {
            for snap in bridges {
                for room in snap.rooms where room.type == "Room" {
                    if let k = ensure(room.name) {
                        map[k]?.hueRooms.append(HueRoomRef(bridgeId: snap.bridge.bridgeId, room: room))
                    }
                }
            }
        }
        // Lutron shades → their area.
        if lutronStatus == .ok {
            for shade in shades {
                if let k = ensure(shade.areaName) { map[k]?.shades.append(shade) }
            }
        }
        // Nest thermostats → their room.
        if nestStatus == .ok {
            for t in thermostats {
                if let k = ensure(t.roomName) { map[k]?.thermostats.append(t) }
            }
        }
        // Sonos groups → their (possibly bonded) room name.
        if sonosStatus == .ok {
            for g in sonosGroups {
                if let k = ensure(g.roomName) { map[k]?.speakers.append(g) }
            }
        }
        // HomeKit locks / plugs / sensors that DO carry a room. Room-less ones fall to Whole house.
        if homekitStatus == .ok, let inv = homekitInventory {
            for a in inv.lockAccessories { if let k = ensure(a.room ?? "") { map[k]?.locks.append(a) } }
            for a in inv.powerAccessories { if let k = ensure(a.room ?? "") { map[k]?.plugs.append(a) } }
            for a in inv.sensorAccessories { if let k = ensure(a.room ?? "") { map[k]?.sensors.append(a) } }
        }

        return order.compactMap { map[$0] }.sorted { lhs, rhs in
            if lhs.deviceCount != rhs.deviceCount { return lhs.deviceCount > rhs.deviceCount }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Reachable HomeKit locks with no room — bound for the "Whole house" bucket in Rooms mode.
    var wholeHouseLocks: [HKAccessory] {
        guard homekitStatus == .ok, let inv = homekitInventory else { return [] }
        return inv.lockAccessories.filter { normalizedRoomKey($0.room ?? "") == nil }
    }

    /// Reachable HomeKit plugs/switches with no room — Whole house.
    var wholeHousePlugs: [HKAccessory] {
        guard homekitStatus == .ok, let inv = homekitInventory else { return [] }
        return inv.powerAccessories.filter { normalizedRoomKey($0.room ?? "") == nil }
    }

    /// Reachable HomeKit sensors with no room — Whole house.
    var wholeHouseSensors: [HKAccessory] {
        guard homekitStatus == .ok, let inv = homekitInventory else { return [] }
        return inv.sensorAccessories.filter { normalizedRoomKey($0.room ?? "") == nil }
    }

    /// Whether the "Whole house" section has anything to show in Rooms mode: water and garage are always
    /// whole-house, plus any room-less HomeKit device, plus the HomeKit "All devices" discovery link.
    var hasWholeHouseContent: Bool {
        hubspaceStatus == .ok
            || garageStatus == .ok
            || homekitStatus == .ok
            || !wholeHouseLocks.isEmpty || !wholeHousePlugs.isEmpty || !wholeHouseSensors.isEmpty
    }
}
