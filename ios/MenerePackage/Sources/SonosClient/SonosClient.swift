import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// UPnP client for Sonos speakers (P15-C2) — the third smart-home ecosystem, built to the same playbook
/// as `HueClient` (P12) and `LutronClient` (P15-C1): a tiny, purpose-built consumer with a stateful
/// MOCK mode for speaker-less verification. Deliberately narrow: discover players, read now-playing +
/// volume, and play/pause/set-volume — no favorites, queue, or library browsing (future).
///
/// **No credential, no pairing.** Sonos is pure LAN UPnP — players advertise via Bonjour (`_sonos._tcp`)
/// and answer SOAP on port 1400 with no authentication. Discovery is the whole setup, so unlike Hue's
/// app key or Lutron's client cert there is nothing to store; the optional `SonosConfig` only forces the
/// mock (`mock: true`) or carries a cosmetic `roomOrder`. `config` is therefore `SonosConfig?` and may
/// be nil (absent doc = live discovery).
///
/// **Group-aware (the SoCo pattern).** Every verb takes a `SonosSpeaker`; callers pass the group
/// **coordinator** (solo players are their own coordinator). Grouping comes from `ZoneGroupTopology`.
///
/// **Ported concept, not code:** the SOAP framing + service URLs are faithful to SoCo (`core.py`,
/// `services.py`, `groups.py`) and node-sonos (`lib/sonos.js`); see `SonosSOAP.swift`.
@DependencyClient
public struct SonosClient: Sendable {
    /// mDNS-discover the household's Sonos players (`_sonos._tcp` → resolve → ZoneGroupTopology). Each
    /// carries its room name, group id, and coordinator flag. `config?.isMock` serves fixtures instead.
    public var discover: @Sendable (_ config: SonosConfig?) async throws -> [SonosSpeaker]
    /// The coordinator's now-playing (title/artist/album-art + transport state).
    public var nowPlaying: @Sendable (_ config: SonosConfig?, _ speaker: SonosSpeaker) async throws -> SonosNowPlaying
    /// The coordinator's group volume (0–100).
    public var volume: @Sendable (_ config: SonosConfig?, _ speaker: SonosSpeaker) async throws -> Int

    // SEAM (P14): agent tools wrap these verbs — "play the living room", "pause the office", "turn the
    // kitchen down to 15" resolve to `play` / `pause` / `setVolume` on the group coordinator. The verbs
    // are reducer-independent (plain client calls keyed off a `SonosConfig?`) so the agent harness calls
    // them exactly as the House UI does. Callers MUST debounce volume-slider spam (the House reducer
    // does — see `HouseReducer`, the same ≥150ms trailing debounce the Hue/Lutron sliders use).

    /// Start playback on the coordinator (AVTransport `Play`).
    public var play: @Sendable (_ config: SonosConfig?, _ speaker: SonosSpeaker) async throws -> Void
    /// Pause the coordinator (AVTransport `Pause`).
    public var pause: @Sendable (_ config: SonosConfig?, _ speaker: SonosSpeaker) async throws -> Void
    /// Set the coordinator's group volume 0–100 (RenderingControl `SetVolume`, Master channel).
    public var setVolume: @Sendable (_ config: SonosConfig?, _ speaker: SonosSpeaker, _ volume: Int) async throws -> Void
}

// MARK: - Live

extension SonosClient: DependencyKey {
    public static var liveValue: SonosClient {
        SonosClient(
            discover: { config in
                if config?.isMock == true { return await SonosMockStore.shared.speakers() }
                return try await SonosTransport.discover()
            },
            nowPlaying: { config, speaker in
                config?.isMock == true
                    ? await SonosMockStore.shared.nowPlaying(id: speaker.id)
                    : try await SonosTransport.nowPlaying(speaker)
            },
            volume: { config, speaker in
                config?.isMock == true
                    ? await SonosMockStore.shared.volume(id: speaker.id)
                    : try await SonosTransport.volume(speaker)
            },
            play: { config, speaker in
                if config?.isMock == true { await SonosMockStore.shared.setState(id: speaker.id, .playing); return }
                try await SonosTransport.play(speaker)
            },
            pause: { config, speaker in
                if config?.isMock == true { await SonosMockStore.shared.setState(id: speaker.id, .paused); return }
                try await SonosTransport.pause(speaker)
            },
            setVolume: { config, speaker, volume in
                if config?.isMock == true { await SonosMockStore.shared.setVolume(id: speaker.id, volume); return }
                try await SonosTransport.setVolume(speaker, volume)
            }
        )
    }

    /// A safe, no-network preview/test value: three mock groups' worth of players, verbs are no-ops that
    /// serve fixtures. (The `@DependencyClient` default would be `unimplemented`; this keeps any reducer
    /// that discovers on `.task` from failing when a test doesn't inject Sonos.)
    public static let previewValue = SonosClient(
        discover: { _ in SonosFixtures.speakers },
        nowPlaying: { _, speaker in SonosFixtures.nowPlaying[speaker.id] ?? SonosNowPlaying(state: .stopped) },
        volume: { _, speaker in SonosFixtures.volume[speaker.id] ?? 20 },
        play: { _, _ in },
        pause: { _, _ in },
        setVolume: { _, _, _ in }
    )

    /// Test value degrades to "no speakers" so a reducer's discovery effect is a silent no-op unless a
    /// test injects a Sonos client explicitly.
    public static let testValue = SonosClient(
        discover: { _ in [] },
        nowPlaying: { _, _ in SonosNowPlaying(state: .stopped) },
        volume: { _, _ in 0 },
        play: { _, _ in },
        pause: { _, _ in },
        setVolume: { _, _, _ in }
    )
}

public extension DependencyValues {
    var sonos: SonosClient {
        get { self[SonosClient.self] }
        set { self[SonosClient.self] = newValue }
    }
}

// MARK: - Fixtures (MOCK MODE)

/// The believable "Place house" speaker fixtures served when a config's `mock == true` (or in previews).
/// Three solo players (each its own coordinator): the **Living room** turntable-adjacent player spinning
/// a record, the **Kitchen** idle, the **M&V Office** paused. Shared by the live client's mock branch,
/// `previewValue`, and the stateful `SonosMockStore` seed.
public enum SonosFixtures {
    public static let living = SonosSpeaker(id: "RINCON_LIVING01400", name: "Living room", ip: "127.0.0.1", groupId: "RINCON_LIVING01400:1", isCoordinator: true)
    public static let kitchen = SonosSpeaker(id: "RINCON_KITCHEN01400", name: "Kitchen", ip: "127.0.0.1", groupId: "RINCON_KITCHEN01400:2", isCoordinator: true)
    public static let office = SonosSpeaker(id: "RINCON_OFFICE01400", name: "M&V Office", ip: "127.0.0.1", groupId: "RINCON_OFFICE01400:3", isCoordinator: true)

    public static let speakers: [SonosSpeaker] = [living, kitchen, office]

    public static let nowPlaying: [String: SonosNowPlaying] = [
        living.id: SonosNowPlaying(title: "Kind of Blue", artist: "Miles Davis", albumArtURL: nil, state: .playing),
        kitchen.id: SonosNowPlaying(state: .stopped),
        office.id: SonosNowPlaying(title: "Harvest Moon", artist: "Neil Young", albumArtURL: nil, state: .paused),
    ]

    public static let volume: [String: Int] = [
        living.id: 28,
        kitchen.id: 15,
        office.id: 20,
    ]
}

// MARK: - Stateful mock store (MOCK MODE)

/// In-memory, per-session mutable now-playing + volume for a mock config — the mock's single source of
/// truth, seeded lazily from `SonosFixtures`, mutated by play/pause/setVolume. Mirrors `LutronMockStore`:
/// writes persist for the process lifetime so the House "Speakers" section's optimistic edits agree on
/// re-read; a fresh launch re-seeds.
actor SonosMockStore {
    static let shared = SonosMockStore()

    private var nowPlayingByID: [String: SonosNowPlaying] = [:]
    private var volumeByID: [String: Int] = [:]
    private var seeded = false

    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        nowPlayingByID = SonosFixtures.nowPlaying
        volumeByID = SonosFixtures.volume
    }

    func speakers() -> [SonosSpeaker] {
        seedIfNeeded()
        return SonosFixtures.speakers
    }

    func nowPlaying(id: String) -> SonosNowPlaying {
        seedIfNeeded()
        return nowPlayingByID[id] ?? SonosNowPlaying(state: .stopped)
    }

    func volume(id: String) -> Int {
        seedIfNeeded()
        return volumeByID[id] ?? 0
    }

    func setState(id: String, _ state: SonosNowPlaying.PlaybackState) {
        seedIfNeeded()
        var np = nowPlayingByID[id] ?? SonosNowPlaying(state: .stopped)
        np.state = state
        nowPlayingByID[id] = np
    }

    func setVolume(id: String, _ volume: Int) {
        seedIfNeeded()
        volumeByID[id] = SonosVolume.clamp(volume)
    }

    /// Re-seed from fixtures — used by tests for order-independent isolation.
    func reset() {
        seeded = false
        nowPlayingByID.removeAll()
        volumeByID.removeAll()
        seedIfNeeded()
    }
}
