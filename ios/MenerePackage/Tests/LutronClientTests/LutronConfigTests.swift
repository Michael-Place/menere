import FamilyDomain
import Foundation
import Testing

/// Decode-safety for `LutronConfig` and the `HueRitual.shadeActions` extension (P15-C1). Both must
/// survive partial / mock / legacy docs — the same decode-safe contract every family config carries.
struct LutronConfigTests {

    @Test func mockDocDecodesWithoutPEMs() throws {
        // The exact shape seeded via the Admin SDK for bridge-less verification.
        let json = #"{"bridgeIP":"192.168.1.50","mock":true}"#
        let config = try JSONDecoder().decode(LutronConfig.self, from: Data(json.utf8))
        #expect(config.bridgeIP == "192.168.1.50")
        #expect(config.isMock)
        #expect(config.clientCertPEM.isEmpty)   // absent PEMs default to ""
        #expect(config.clientKeyPEM.isEmpty)
        #expect(config.bridgeCAPEM.isEmpty)
        #expect(config.areaNames == nil)
    }

    @Test func fullDocRoundTrips() throws {
        let original = LutronConfig(
            bridgeIP: "10.0.0.9", bridgeId: "bridge-1", name: "Caseta",
            clientCertPEM: "C", clientKeyPEM: "K", bridgeCAPEM: "A",
            areaNames: ["5": "Oliver's room shade"], mock: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LutronConfig.self, from: data)
        #expect(decoded == original)
        #expect(decoded.overrideName(forZone: "5") == "Oliver's room shade")
        #expect(decoded.displayName == "Caseta")
    }

    @Test func ritualWithoutShadeActionsIsHueOnly() throws {
        // Pre-P15 ritual JSON (no shadeActions) → nil, exactly the old behavior.
        let json = #"{"key":"bedtime","label":"Bedtime","sceneId":"s","groupId":"3","bridgeId":"b"}"#
        let ritual = try JSONDecoder().decode(HueRitual.self, from: Data(json.utf8))
        #expect(ritual.shadeActions == nil)
    }

    @Test func ritualWithShadeActionsDecodes() throws {
        let json = #"""
        {"key":"bedtime","label":"Bedtime","sceneId":"s","groupId":"3","bridgeId":"b",
         "shadeActions":[{"zoneId":"5","level":0},{"zoneId":"6","level":0}]}
        """#
        let ritual = try JSONDecoder().decode(HueRitual.self, from: Data(json.utf8))
        #expect(ritual.shadeActions?.count == 2)
        #expect(ritual.shadeActions?.first == ShadeAction(zoneId: "5", level: 0))
    }
}
