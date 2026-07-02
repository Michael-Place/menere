import Dependencies
import FamilyDomain
import Foundation
import Testing

@testable import LutronClient

/// Locks the MOCK-mode statefulness (P15-C1): a mock config's shade reads flow through
/// `LutronMockStore`, so a `setShadeLevel` / raise / lower persists and a re-read agrees — the same
/// contract `HueMockStore` gives the Hue House surface. Serialized + reset-per-test because the store
/// is a process-wide singleton (parallel tests would otherwise see each other's writes).
@Suite(.serialized)
struct LutronMockStoreTests {
    private var mockConfig: LutronConfig {
        LutronConfig(bridgeIP: "192.168.1.50", mock: true)
    }

    @Test func mockShadesReturnFixtures() async throws {
        await LutronMockStore.shared.reset()
        let client = LutronClient.liveValue
        let shades = try await client.shades(mockConfig)
        #expect(shades.count == 3)
        #expect(shades.contains { $0.name == "Oliver's room shade" && $0.level == 100 })
        #expect(shades.contains { $0.name == "Living room shades" && $0.level == 45 })
    }

    @Test func setLevelPersistsAcrossReads() async throws {
        // Fresh store so this test is order-independent.
        await LutronMockStore.shared.reset()
        let client = LutronClient.liveValue
        try await client.setShadeLevel(mockConfig, "8", 20)
        let shades = try await client.shades(mockConfig)
        #expect(shades.first { $0.zoneId == "8" }?.level == 20)
    }

    @Test func raiseAndLowerMoveToExtremes() async throws {
        await LutronMockStore.shared.reset()
        let client = LutronClient.liveValue
        try await client.lower(mockConfig, "5")   // close
        var shades = try await client.shades(mockConfig)
        #expect(shades.first { $0.zoneId == "5" }?.level == 0)

        try await client.raise(mockConfig, "5")    // open
        shades = try await client.shades(mockConfig)
        #expect(shades.first { $0.zoneId == "5" }?.level == 100)
    }

    @Test func setLevelClampsInMock() async throws {
        await LutronMockStore.shared.reset()
        let client = LutronClient.liveValue
        try await client.setShadeLevel(mockConfig, "6", 250)
        let shades = try await client.shades(mockConfig)
        #expect(shades.first { $0.zoneId == "6" }?.level == 100)
    }
}
