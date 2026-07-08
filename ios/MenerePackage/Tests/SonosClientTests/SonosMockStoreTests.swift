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

    /// Next/previous walk the fixture queue and wrap at the ends; a re-read reflects the new track.
    @Test func skipAdvancesAndWrapsTheQueue() async throws {
        await SonosMockStore.shared.reset()
        let client = SonosClient.liveValue
        // Living room seeds on "Kind of Blue" (queue index 0).
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.living).title == "Kind of Blue")
        try await client.next(mockConfig, SonosFixtures.living)
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.living).title == "So What")
        try await client.next(mockConfig, SonosFixtures.living)
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.living).title == "Blue in Green")
        // Wrap forward → back to the top of the queue.
        try await client.next(mockConfig, SonosFixtures.living)
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.living).title == "Kind of Blue")
        // Previous wraps backward to the tail.
        try await client.previous(mockConfig, SonosFixtures.living)
        let np = try await client.nowPlaying(mockConfig, SonosFixtures.living)
        #expect(np.title == "Blue in Green")
        #expect(np.state == .playing)   // a skip resumes playback
    }

    /// A skip on a speaker with no fixture queue (idle Kitchen) is a no-op.
    @Test func skipIsNoOpWithoutAQueue() async throws {
        await SonosMockStore.shared.reset()
        let client = SonosClient.liveValue
        try await client.next(mockConfig, SonosFixtures.kitchen)
        #expect(try await client.nowPlaying(mockConfig, SonosFixtures.kitchen).line == "Idle")
    }

    /// SetMute persists across reads and starts unmuted.
    @Test func muteTogglePersistsAcrossReads() async throws {
        await SonosMockStore.shared.reset()
        let client = SonosClient.liveValue
        #expect(try await client.mute(mockConfig, SonosFixtures.office) == false)
        try await client.setMute(mockConfig, SonosFixtures.office, true)
        #expect(try await client.mute(mockConfig, SonosFixtures.office) == true)
        // Muting doesn't touch the volume level.
        #expect(try await client.volume(mockConfig, SonosFixtures.office) == 20)
        try await client.setMute(mockConfig, SonosFixtures.office, false)
        #expect(try await client.mute(mockConfig, SonosFixtures.office) == false)
    }
}
