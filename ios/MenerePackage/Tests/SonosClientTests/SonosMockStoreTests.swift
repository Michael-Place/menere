import Dependencies
import FamilyDomain
import Foundation
import Testing

@testable import SonosClient

/// Locks the MOCK-mode statefulness (P15-C2): a mock config's reads flow through `SonosMockStore`, so a
/// play/pause/setVolume persists and a re-read agrees — the same contract `LutronMockStore` gives the
/// House shades. Serialized + reset-per-test because the store is a process-wide singleton.
@Suite(.serialized)
struct SonosMockStoreTests {
    private var mockConfig: SonosConfig { SonosConfig(mock: true) }

    @Test func mockDiscoverReturnsThreeFixtures() async throws {
        await SonosMockStore.shared.reset()
        let client = SonosClient.liveValue
        let speakers = try await client.discover(mockConfig)
        #expect(speakers.count == 3)
        #expect(speakers.contains { $0.name == "Living room" })
        #expect(speakers.contains { $0.name == "Kitchen" })
        #expect(speakers.contains { $0.name == "M&V Office" })
        // Living room is playing a record-appropriate title; Kitchen idle; Office paused.
        let living = try await client.nowPlaying(mockConfig, SonosFixtures.living)
        #expect(living.state == .playing)
        #expect(living.line == "Kind of Blue — Miles Davis")
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.kitchen).line == "Idle")
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.office).state == .paused)
    }

    @Test func playPausePersistsAcrossReads() async throws {
        await SonosMockStore.shared.reset()
        let client = SonosClient.liveValue
        // Pause the living room → a re-read reflects paused.
        try await client.pause(mockConfig, SonosFixtures.living)
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.living).state == .paused)
        // Resume the office → playing.
        try await client.play(mockConfig, SonosFixtures.office)
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.office).state == .playing)
    }

    @Test func setVolumePersistsAndClamps() async throws {
        await SonosMockStore.shared.reset()
        let client = SonosClient.liveValue
        try await client.setVolume(mockConfig, SonosFixtures.kitchen, 55)
        #expect(try await client.volume(mockConfig, SonosFixtures.kitchen) == 55)
        try await client.setVolume(mockConfig, SonosFixtures.kitchen, 250)
        #expect(try await client.volume(mockConfig, SonosFixtures.kitchen) == 100)   // clamped
    }
}
