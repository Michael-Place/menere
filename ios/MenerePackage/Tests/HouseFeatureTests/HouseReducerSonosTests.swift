import ComposableArchitecture
import FamilyDomain
import HueClient
import SonosClient
import Testing

@testable import HouseFeature

/// Locks the P15-C2 Sonos verbs on `HouseReducer`: play/pause is optimistic on the group coordinator,
/// and the volume slider REUSES the established ≥150ms trailing debounce (the same floor as the Hue and
/// Lutron sliders) so a drag collapses to a single `SetVolume`.
@MainActor
struct HouseReducerSonosTests {
    private actor VolumeCounter {
        private(set) var sets: [(String, Int)] = []
        func record(_ id: String, _ v: Int) { sets.append((id, v)) }
        var count: Int { sets.count }
        var last: Int? { sets.last?.1 }
    }

    private let bridge = HueBridgeConfig(bridgeId: "B", bridgeIP: "10.0.0.1", applicationKey: "k")

    private func makeState() -> HouseReducer.State {
        let group = SonosGroup(
            coordinator: SonosFixtures.living, members: [SonosFixtures.living],
            nowPlaying: SonosNowPlaying(title: "Kind of Blue", artist: "Miles Davis", state: .playing),
            volume: 28
        )
        return HouseReducer.State(
            config: HueConfig(bridges: [bridge]), bridges: [],
            sonosConfig: SonosConfig(mock: true), sonosGroups: [group]
        )
    }

    /// Play/pause flips the coordinator's transport state locally before the write lands.
    @Test func playPauseIsOptimistic() async {
        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.sonos = .previewValue
        }
        store.exhaustivity = .off

        await store.send(.toggleSonosPlayback(groupId: SonosFixtures.living.groupKey)) {
            $0.sonosGroups[0].nowPlaying.state = .paused
        }
        await store.send(.toggleSonosPlayback(groupId: SonosFixtures.living.groupKey)) {
            $0.sonosGroups[0].nowPlaying.state = .playing
        }
    }

    /// Five rapid volume events → zero writes while dragging, exactly one after 150ms of quiet.
    @Test func volumeSliderSpamCollapsesToOneWrite() async {
        let clock = TestClock()
        let counter = VolumeCounter()
        var client = SonosClient.previewValue
        client.setVolume = { _, speaker, v in await counter.record(speaker.id, v) }

        let store = TestStore(initialState: makeState()) { HouseReducer() } withDependencies: {
            $0.continuousClock = clock
            $0.sonos = client
        }
        store.exhaustivity = .off

        let gid = SonosFixtures.living.groupKey
        for v in [10, 20, 30, 40, 50] {
            await store.send(.sonosVolumeChanged(groupId: gid, volume: v))
        }
        #expect(await counter.count == 0)   // still dragging

        await clock.advance(by: .milliseconds(150))
        await store.receive(\.commitSonosVolume)
        await store.finish()
        #expect(await counter.count == 1)   // one SetVolume despite five deltas
        #expect(await counter.last == 50)
    }
}
