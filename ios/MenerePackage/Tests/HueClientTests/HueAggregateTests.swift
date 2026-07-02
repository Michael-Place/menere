import Dependencies
import FamilyDomain
import Foundation
import Testing

@testable import HueClient

/// Locks the P12-C3 aggregate helpers `readBridge` / `readHouse`: per-bridge resilience so one
/// unreachable (or throwing) bridge never hides another's data, and per-read degradation so a single
/// failed read on a reachable bridge yields empty rather than dropping the whole bridge.
struct HueAggregateTests {
    private let good = HueBridgeConfig(bridgeId: "GOOD", bridgeIP: "10.0.0.1", applicationKey: "kg")
    private let bad = HueBridgeConfig(bridgeId: "BAD", bridgeIP: "10.0.0.2", applicationKey: "kb")

    /// Base off `previewValue` (fully implemented) so we never trip the live-dependency guard;
    /// override just the endpoints under test.
    private func client() -> HueClient {
        var c = HueClient.previewValue
        c.testConnection = { bridge in
            if bridge.bridgeId == "BAD" { throw HueError.bridgeUnreachable }
            return true
        }
        c.rooms = { _ in [HueRoom(id: "1", name: "Living room", type: "Room", lightIds: ["1"], anyOn: true)] }
        c.lights = { _ in [HueLight(id: "1", name: "Lamp", isOn: true)] }
        c.scenes = { _ in [HueScene(id: "s", name: "Bedtime", groupId: "1")] }
        c.temperatures = { _ in [HueTemperature(sensorId: "27", tempF: 71, lastUpdated: nil)] }
        return c
    }

    @Test func readHouseMergesHealthyAndDropsUnreachable() async {
        let c = client()
        let snapshots = await c.readHouse([good, bad])
        // Only the reachable bridge survives.
        #expect(snapshots.map(\.bridge.bridgeId) == ["GOOD"])
        #expect(snapshots.first?.lights.count == 1)
        #expect(snapshots.first?.temperatures.first?.tempF == 71)
    }

    @Test func readHouseEmptyWhenNoBridgeReachable() async {
        var c = HueClient.previewValue
        c.testConnection = { _ in throw HueError.bridgeUnreachable }
        let snapshots = await c.readHouse([good, bad])
        #expect(snapshots.isEmpty)
    }

    @Test func readBridgeDegradesAFailedReadToEmpty() async throws {
        var c = HueClient.previewValue
        c.testConnection = { _ in true }
        c.rooms = { _ in throw HueError.invalidResponse }   // this read fails
        c.lights = { _ in [HueLight(id: "1", name: "Lamp", isOn: true)] }
        c.scenes = { _ in [] }
        c.temperatures = { _ in [HueTemperature(sensorId: "27", tempF: 70, lastUpdated: nil)] }

        let snapshot = try await c.readBridge(good)
        #expect(snapshot.rooms.isEmpty)                      // degraded to empty, not thrown
        #expect(snapshot.lights.count == 1)                 // other reads still land
        #expect(snapshot.temperatures.first?.tempF == 70)
    }

    @Test func readBridgeThrowsWhenUnreachable() async {
        var c = HueClient.previewValue
        c.testConnection = { _ in false }
        await #expect(throws: HueError.self) {
            _ = try await c.readBridge(good)
        }
    }
}
