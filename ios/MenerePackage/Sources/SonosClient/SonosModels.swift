import Foundation

// Client-surface value types for the Sonos speakers integration (P15-C2). These describe *live* LAN
// state (players, their grouping, and now-playing/volume); there is no identity/credential half — Sonos
// needs neither (see `FamilyDomain.SonosConfig`). All are Foundation-clean, Sendable, and Equatable so
// they flow through TCA state.

/// One Sonos player discovered on the LAN (`_sonos._tcp` → ZoneGroupTopology). A player is always a
/// member of exactly one *group*; a solo player is a group of one and its own coordinator. Control
/// (play/pause/volume/now-playing) is always addressed to the group **coordinator** — the SoCo pattern.
public struct SonosSpeaker: Equatable, Sendable, Identifiable {
    /// The player UID (`RINCON_…01400`) — stable identity from ZoneGroupTopology.
    public let id: String
    /// The player's room name (Sonos `ZoneName` / device-description `roomName`), e.g. "Living Room".
    public let name: String
    /// The player's LAN IP (from its topology `Location` URL), for UPnP calls on port 1400.
    public let ip: String
    /// The id of the group this player belongs to (ZoneGroup `ID`). Nil only on a degraded
    /// description-only discovery, where each player is treated as its own solo group.
    public let groupId: String?
    /// True when this player is the coordinator of its group (the control target).
    public let isCoordinator: Bool

    public init(id: String, name: String, ip: String, groupId: String? = nil, isCoordinator: Bool = true) {
        self.id = id
        self.name = name
        self.ip = ip
        self.groupId = groupId
        self.isCoordinator = isCoordinator
    }

    /// The group key: the explicit `groupId`, else the player's own id (a solo group).
    public var groupKey: String { groupId ?? id }
}

/// A group's now-playing snapshot, parsed from the coordinator's `GetTransportInfo` +
/// `GetPositionInfo` (DIDL-Lite `TrackMetaData`). Radio/line-in tracks may carry no title/artist.
public struct SonosNowPlaying: Equatable, Sendable {
    /// AVTransport `CurrentTransportState`, folded to the three states the UI cares about.
    public enum PlaybackState: String, Equatable, Sendable {
        case playing, paused, stopped
    }

    /// DIDL-Lite `dc:title` (track title), when present.
    public var title: String?
    /// DIDL-Lite `dc:creator` (artist), when present.
    public var artist: String?
    /// DIDL-Lite `upnp:albumArtURI`, resolved to an absolute URL on the speaker (`http://ip:1400/…`).
    public var albumArtURL: URL?
    /// Current transport state.
    public var state: PlaybackState

    public init(title: String? = nil, artist: String? = nil, albumArtURL: URL? = nil, state: PlaybackState = .stopped) {
        self.title = title
        self.artist = artist
        self.albumArtURL = albumArtURL
        self.state = state
    }

    public var isPlaying: Bool { state == .playing }

    /// A one-line now-playing label: "Kind of Blue — Miles Davis", "Kind of Blue", or "Idle" when
    /// there's no track (or a stopped player with no metadata).
    public var line: String {
        switch (title, artist) {
        case let (title?, artist?) where !title.isEmpty && !artist.isEmpty:
            return "\(title) — \(artist)"
        case let (title?, _) where !title.isEmpty:
            return title
        default:
            return "Idle"
        }
    }
}

/// A UI-facing Sonos *group* row: its coordinator, all member players, and the coordinator's live
/// now-playing + volume. One row per group renders on the House "Speakers" section; controls address
/// the coordinator. Assembled from `[SonosSpeaker]` + per-coordinator reads by `assemble`.
public struct SonosGroup: Equatable, Sendable, Identifiable {
    /// The group key (coordinator's `groupKey`) — the row id and control-routing key.
    public let id: String
    /// The coordinator player — the control target for play/pause/volume/now-playing.
    public let coordinator: SonosSpeaker
    /// All players in the group (coordinator included), sorted by name.
    public let members: [SonosSpeaker]
    /// The coordinator's now-playing snapshot.
    public var nowPlaying: SonosNowPlaying
    /// The group volume (coordinator's `RenderingControl` Master volume) 0–100.
    public var volume: Int

    public init(coordinator: SonosSpeaker, members: [SonosSpeaker], nowPlaying: SonosNowPlaying, volume: Int) {
        self.id = coordinator.groupKey
        self.coordinator = coordinator
        self.members = members.sorted { $0.name < $1.name }
        self.nowPlaying = nowPlaying
        self.volume = SonosVolume.clamp(volume)
    }

    /// The display room label: a single room, or joined rooms for a bonded/grouped set
    /// ("Living Room + Kitchen"). Coordinator first, then the rest by name.
    public var roomName: String {
        let names = ([coordinator] + members.filter { $0.id != coordinator.id }).map(\.name)
        return names.joined(separator: " + ")
    }

    /// Group a flat player list into `(coordinator, members)` skeletons, ordered for display.
    /// Solo players are their own coordinator. `order` (from `SonosConfig.roomOrder`) floats matching
    /// rooms to the front, case-insensitively; everything else falls to the back alphabetically.
    public static func assemble(
        from speakers: [SonosSpeaker], order: [String]? = nil
    ) -> [(coordinator: SonosSpeaker, members: [SonosSpeaker])] {
        let grouped = Dictionary(grouping: speakers, by: \.groupKey)
        var rows: [(coordinator: SonosSpeaker, members: [SonosSpeaker])] = grouped.values.map { members in
            let coordinator = members.first(where: \.isCoordinator) ?? members.sorted { $0.name < $1.name }[0]
            return (coordinator, members.sorted { $0.name < $1.name })
        }

        let lowerOrder = (order ?? []).map { $0.lowercased() }
        func rank(_ row: (coordinator: SonosSpeaker, members: [SonosSpeaker])) -> Int {
            let names = row.members.map { $0.name.lowercased() }
            let idx = lowerOrder.firstIndex { o in names.contains(o) }
            return idx ?? Int.max
        }
        rows.sort {
            let (a, b) = (rank($0), rank($1))
            return a == b ? $0.coordinator.name < $1.coordinator.name : a < b
        }
        return rows
    }
}

/// Helpers for Sonos group volume — already the UPnP native 0–100 scale (`RenderingControl` Master),
/// so the House slider maps straight through. Kept pure (no reducer/view) so the P14 agent tools
/// ("turn the living room down to 20") resolve a volume through the same clamp the UI uses.
public enum SonosVolume {
    public static let min = 0
    public static let max = 100

    /// Clamp an arbitrary integer to the 0–100 volume range.
    public static func clamp(_ volume: Int) -> Int {
        Swift.max(min, Swift.min(max, volume))
    }
}
