import FamilyDomain
import Foundation
import Testing

/// Locks the P12-C3 multi-bridge migration: a legacy single-bridge `config/hue` doc (the shape
/// P12-C1/C2 wrote — and the shape currently live on Michael's household) must decode into the new
/// `bridges` array **losslessly**, with rituals + sensor maps scoped to that bridge's id, and the
/// new shape must round-trip. Uses a FAKE app key (never the real secret).
struct HueConfigMigrationTests {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Mirrors Michael's exact live-doc field shape (fake key): empty rituals, empty sensorLabels,
    /// one sensorName under id "27".
    private let michaelLegacyJSON = """
    {
      "applicationKey": "FAKEKEY0123456789ABCDEF0123456789ABCDEF",
      "bridgeIP": "192.168.1.233",
      "bridgeId": "ECB5FAFFFE9D3669",
      "rituals": [],
      "sensorLabels": {},
      "sensorNames": { "27": "Hue temperature sensor 1" }
    }
    """.data(using: .utf8)!

    @Test func michaelLiveDocMigratesLosslessly() throws {
        let config = try decoder.decode(HueConfig.self, from: michaelLegacyJSON)

        // Exactly one bridge, key + id preserved verbatim.
        #expect(config.bridges.count == 1)
        let bridge = try #require(config.bridges.first)
        #expect(bridge.bridgeId == "ECB5FAFFFE9D3669")
        #expect(bridge.bridgeIP == "192.168.1.233")
        #expect(bridge.applicationKey == "FAKEKEY0123456789ABCDEF0123456789ABCDEF")
        #expect(bridge.name == nil)
        #expect(bridge.mock == nil)

        // Empty rituals; the single sensorName scoped under the bridge id.
        #expect(config.rituals.isEmpty)
        #expect(config.sensorLabels.isEmpty)
        #expect(config.sensorNames == ["ECB5FAFFFE9D3669": ["27": "Hue temperature sensor 1"]])
    }

    @Test func michaelDocSurvivesReencodeRoundTrip() throws {
        // Decode legacy → encode NEW shape → decode again: the key must still be verbatim.
        let once = try decoder.decode(HueConfig.self, from: michaelLegacyJSON)
        let reencoded = try encoder.encode(once)
        let twice = try decoder.decode(HueConfig.self, from: reencoded)
        #expect(twice == once)
        #expect(twice.bridges.first?.applicationKey == "FAKEKEY0123456789ABCDEF0123456789ABCDEF")
        // The re-encoded doc is the NEW shape: has "bridges", no top-level "bridgeId".
        let json = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(json["bridges"] != nil)
        #expect(json["bridgeId"] == nil)
        #expect(json["applicationKey"] == nil)
    }

    @Test func legacyRitualsAndSensorLabelsScopeToTheBridge() throws {
        let legacy = """
        {
          "applicationKey": "K",
          "bridgeIP": "1.1.1.1",
          "bridgeId": "BID",
          "rituals": [
            { "key": "bedtime", "label": "Bedtime", "sceneId": "s3", "groupId": "3" }
          ],
          "sensorLabels": { "27": "Oliver's room" },
          "sensorNames": { "27": "Nursery sensor" },
          "mock": true
        }
        """.data(using: .utf8)!

        let config = try decoder.decode(HueConfig.self, from: legacy)
        // Legacy ritual (no bridgeId) gets scoped to the single bridge.
        #expect(config.rituals.count == 1)
        #expect(config.rituals.first?.bridgeId == "BID")
        // Flat sensor maps nest under the bridge id.
        #expect(config.sensorLabels == ["BID": ["27": "Oliver's room"]])
        #expect(config.sensorNames == ["BID": ["27": "Nursery sensor"]])
        // Legacy top-level `mock` propagates to the single migrated bridge.
        #expect(config.bridges.first?.isMock == true)
    }

    @Test func newMultiBridgeShapeRoundTrips() throws {
        let config = HueConfig(
            bridges: [
                HueBridgeConfig(bridgeId: "A", bridgeIP: "10.0.0.1", applicationKey: "ka", name: "Downstairs"),
                HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.2", applicationKey: "kb", name: "Upstairs"),
            ],
            rituals: [
                HueRitual(key: "dinner", label: "Dinner's ready", sceneId: "d", groupId: "1", bridgeId: "A"),
                HueRitual(key: "bedtime", label: "Bedtime", sceneId: "b", groupId: "7", bridgeId: "B"),
            ],
            roomOwners: ["1": "oliver"],
            sensorLabels: ["B": ["27": "Oliver's room"]],
            sensorNames: ["B": ["27": "Nursery sensor"]]
        )
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(HueConfig.self, from: data)
        #expect(decoded == config)
        // Ritual routing survives: each ritual keeps its owning bridge id.
        #expect(decoded.rituals.first(where: { $0.key == "bedtime" })?.bridgeId == "B")
    }

    @Test func newShapeWithBridgeIdedRitualsIsNotReMigrated() throws {
        // A doc that already carries `bridges` must NOT trip the legacy branch even if a stray
        // top-level bridgeId were present — presence of `bridges` wins.
        let json = """
        {
          "bridges": [{ "bridgeId": "A", "bridgeIP": "10.0.0.1", "applicationKey": "ka" }],
          "rituals": [{ "key": "dinner", "label": "Dinner", "sceneId": "d", "groupId": "1", "bridgeId": "A" }],
          "sensorLabels": { "A": { "27": "Room" } }
        }
        """.data(using: .utf8)!
        let config = try decoder.decode(HueConfig.self, from: json)
        #expect(config.bridges.map(\.bridgeId) == ["A"])
        #expect(config.rituals.first?.bridgeId == "A")
        #expect(config.sensorLabels == ["A": ["27": "Room"]])
    }
}
