import AnalyticsClient
import ComposableArchitecture
import CoreGraphics
import FamilyDomain
import Foundation
import LocalCache
import MenereUI
import PersistenceClient
import Photos
import PhotoLibraryClient
import StorageClient
import UserDomain

// MARK: - FL3 — "On this day" support types

/// Read-authorization state for the FL3 "On this day" surface, distilled from ``PHAuthorizationStatus``
/// into just the cases the Memories tab reacts to. `.limited` counts as `.ready` (we browse the shared
/// subset).
public enum PhotoAuthState: Equatable, Sendable {
    /// Not checked yet (first render).
    case unknown
    /// `.notDetermined` — offer a gentle "connect your photos" prompt.
    case prompt
    /// `.denied` / `.restricted` — hide the photo affordances (memories still resurface).
    case denied
    /// `.authorized` / `.limited` — load this-date photos.
    case ready

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .authorized, .limited: self = .ready
        case .denied, .restricted: self = .denied
        case .notDetermined: self = .prompt
        @unknown default: self = .prompt
        }
    }
}

/// FL3 — the real library photos taken on today's calendar day, `yearsAgo` years back (grouped so the
/// UI can label "1 year ago" / "3 years ago"). Merged with any on-this-day *memories* in the view.
public struct OnThisDayPhotoGroup: Equatable, Sendable, Identifiable {
    /// How many years back this group is (1…N).
    public let yearsAgo: Int
    /// The anchor day that year (today shifted back `yearsAgo` years) — labels + memory dating.
    public let date: Date
    /// The library assets from that day (± the on-this-day window), newest first.
    public let assets: [PhotoAsset]
    public var id: Int { yearsAgo }

    public init(yearsAgo: Int, date: Date, assets: [PhotoAsset]) {
        self.yearsAgo = yearsAgo
        self.date = date
        self.assets = assets
    }
}

/// The family **Memories** tab (P28-C2) — the scrapbook journal. Loads the household's ``Memory``
/// timeline (newest first), fetches each page's photos/stickers for the collage, and drives the warm
/// create/edit sheet (``MemoryEditorReducer``). A "Capture a moment" entry lives here AND on Today.
@Reducer
public struct MemoriesReducer {
    /// The per-month AI recap lifecycle for the "Recap this month ✨" affordance on a month header.
    public enum RecapPhase: Equatable, Sendable {
        case loading
        case ready(String)
        case failed
    }

    @ObservableState
    public struct State: Equatable {
        public var memories: [Memory] = []
        public var members: [HouseholdMember] = []
        /// Photo + sticker bytes for the timeline, keyed by Storage path (light in-memory cache).
        public var photoCache: [String: Data] = [:]
        public var isLoading = false
        public var hasLoaded = false
        /// The active per-kid timeline filter (`HouseholdMember.id`); `nil` = "All". Filters the
        /// timeline + the "This time last year" section by `kidMemberIds.contains`.
        public var selectedKidId: String?
        /// AI month recaps keyed by month bucket ("yyyy-M"), driving the shimmer + reveal.
        public var recaps: [String: RecapPhase] = [:]
        /// FL3 — read authorization for the "On this day" library photos.
        public var photoAuth: PhotoAuthState = .unknown
        /// FL3 — real library photos taken on today's day across prior years (non-empty years only).
        public var onThisDayPhotos: [OnThisDayPhotoGroup] = []
        /// FL3 — thumbnail bytes for the on-this-day photo strip, keyed by asset id.
        public var onThisDayThumbs: [String: Data] = [:]
        /// FL3-dismiss — device-local (persisted) signatures of on-this-day *groups* the family waved off
        /// as not memory-worthy; skipped on render. Hydrated from @AppStorage on `.task`, written through
        /// on dismiss. No Firestore — this stays on the device.
        public var dismissedOnThisDayGroups: Set<String> = []
        /// FL3-dismiss — device-local (persisted) asset IDs individually waved off ("Not this one");
        /// filtered out of any group they appear in (and out of make-a-memory).
        public var dismissedOnThisDayAssets: Set<String> = []
        @Presents public var editor: MemoryEditorReducer.State?
        /// FL4 — the "People" (tag-a-face) sheet.
        @Presents public var faceTagging: FaceTaggingReducer.State?
        /// D2 — the pending marquee milestone celebration (the app's biggest moment). Non-`nil` from the
        /// instant a milestone-tagged memory saves until the keepsake auto-dismisses (or is tapped away).
        public var milestoneCelebration: MilestoneCelebrationRequest?

        public init() {}

        /// Memories after applying the active per-kid filter (newest-first order preserved).
        public var visibleMemories: [Memory] {
            guard let id = selectedKidId else { return memories }
            return memories.filter { $0.kidMemberIds.contains(id) }
        }

    }

    public enum Action: Equatable {
        case task
        /// `memories == nil` means the Firestore read FAILED (offline) — keep the cache-painted timeline
        /// and skip the write-through. A non-nil (even empty) result is authoritative.
        case loaded(memories: [Memory]?, members: [HouseholdMember])
        case memoriesCacheHydrated([Memory])   // H2-ext — instant/reactive paint from the SQLite mirror
        case photosLoaded([String: Data])
        /// FL3 — the current photo read-authorization was resolved (on load or after a prompt).
        case onThisDayAuthLoaded(PhotoAuthState)
        /// FL3 — the this-date-across-years library photos finished fetching.
        case onThisDayPhotosLoaded([OnThisDayPhotoGroup])
        /// FL3 — thumbnails for the on-this-day strip finished loading.
        case onThisDayThumbsLoaded([String: Data])
        /// FL3 — the soft "connect your photos" prompt was tapped (requests access, then loads).
        case connectPhotosTapped
        /// FL3 — "Make a memory from these" on a year's on-this-day photos.
        case makeMemoryFromOnThisDay(yearsAgo: Int)
        /// FL3-dismiss — the family waved off a whole year's on-this-day suggestion card (the × control);
        /// its exact photo set stays hidden forever.
        case dismissOnThisDayGroup(yearsAgo: Int)
        /// FL3-dismiss — long-press "Not this one" removed a single photo from a suggestion.
        case dismissOnThisDayAsset(id: String)
        /// The Memories-tab button AND the Today quick-action both send this to open a fresh page.
        case captureMomentTapped
        case memoryTapped(Memory)
        /// FL4 — the "People" toolbar button opens the tag-a-face sheet.
        case peopleTapped
        case faceTagging(PresentationAction<FaceTaggingReducer.Action>)
        /// A filter chip was tapped (`nil` = "All").
        case kidFilterSelected(String?)
        /// "Recap this month ✨" tapped on a month header (keyed by month bucket "yyyy-M").
        case recapTapped(monthKey: String)
        case recapLoaded(monthKey: String, recap: String)
        case recapFailed(monthKey: String)
        case editor(PresentationAction<MemoryEditorReducer.Action>)
        /// D2 — the milestone keepsake finished (auto-dismiss timer fired or the family tapped it away).
        case milestoneCelebrationDismissed
    }

    public init() {}

    private enum CancelID { case observeMemoriesCache }

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.analytics) var analytics
    @Dependency(\.memoryRecap) var memoryRecap
    @Dependency(\.localCache) var localCache
    @Dependency(\.date) var date
    @Dependency(\.photoLibrary) var photoLibrary

    /// Best-effort load of every page's photos + stickers into the timeline cache (shared by the
    /// Firestore `.loaded` path and the SQLite `.memoriesCacheHydrated` fast-paint path).
    private func photosEffect(for memories: [Memory], have cache: [String: Data]) -> Effect<Action> {
        let paths = memories.flatMap { $0.photoPaths + $0.stickerPaths }.filter { !$0.isEmpty }
        let missing = paths.filter { cache[$0] == nil }
        guard !missing.isEmpty else { return .none }
        return .run { send in
            var loaded: [String: Data] = [:]
            for path in missing where loaded[path] == nil {
                // H1: cached pipeline → the memory timeline stops re-downloading on every visit.
                if let data = try? await ImagePipeline.shared.data(
                    forStoragePath: path,
                    loader: { try await storage.downloadData(path) }
                ) { loaded[path] = data }
            }
            await send(.photosLoaded(loaded))
        }
    }

    /// FL3 — how many prior years back to look for "On this day" photos + memories.
    static let onThisDayYearSpan = 5
    /// FL3 — ± window (in calendar days) around today's day when matching this-date-across-years.
    static let onThisDayWindowDays = 1

    /// FL3-dismiss — @AppStorage keys for the device-local "not memory-worthy" dismissals (persist across
    /// launches; never Firestore). Group = a whole year's suggestion card; Asset = a single bad photo.
    static let dismissedGroupsKey = "memories.onThisDay.dismissedGroups"
    static let dismissedAssetsKey = "memories.onThisDay.dismissedAssets"

    /// FL3-dismiss — a stable, launch-independent signature for an on-this-day group: an order-independent
    /// FNV-1a hash of its asset IDs. Because the signature *is* the exact photo set, dismissing hides
    /// *those* photos forever, while a genuinely different set on a future day still surfaces. (Swift's
    /// `hashValue` is per-run seeded, so we roll our own deterministic hash for persistence.)
    static func onThisDayGroupSignature(_ assetIDs: [String]) -> String {
        let joined = assetIDs.sorted().joined(separator: "\u{1}")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in joined.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// FL3-dismiss — serialize/parse a dismissal set for @AppStorage. Newline-joined; signatures are hex
    /// and PhotoKit local IDs never contain a newline, so the round-trip is lossless + robust.
    static func encodeDismissals(_ set: Set<String>) -> String { set.sorted().joined(separator: "\n") }
    static func decodeDismissals(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    /// FL3 — fetch the library photos taken on today's day, `1…span` years back. Runs off the main
    /// actor (PhotoKit is thread-safe for fetches); returns only the years that actually have photos.
    static func fetchOnThisDay(now: Date, photoLibrary: PhotoLibraryClient) async -> [OnThisDayPhotoGroup] {
        let cal = Calendar.current
        var groups: [OnThisDayPhotoGroup] = []
        for yearsAgo in 1...onThisDayYearSpan {
            guard let anchor = cal.date(byAdding: .year, value: -yearsAgo, to: now),
                  let range = dayRange(around: anchor, windowDays: onThisDayWindowDays, cal: cal) else { continue }
            let assets = await photoLibrary.fetchAssets(
                PhotoAssetFilter(dateRange: range, mediaType: .image, limit: 30)
            )
            if !assets.isEmpty {
                groups.append(OnThisDayPhotoGroup(yearsAgo: yearsAgo, date: anchor, assets: assets))
            }
        }
        return groups
    }

    /// The inclusive `Date` range covering `anchor`'s day ± `windowDays` full days.
    static func dayRange(around anchor: Date, windowDays: Int, cal: Calendar) -> ClosedRange<Date>? {
        guard let lower = cal.date(byAdding: .day, value: -windowDays, to: anchor),
              let upper = cal.date(byAdding: .day, value: windowDays, to: anchor),
              let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: cal.startOfDay(for: upper))
        else { return nil }
        return cal.startOfDay(for: lower)...end
    }

    /// The month bucket key for a date ("yyyy-M") — shared by the reducer + timeline grouping.
    static func monthKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }

    /// A human month label ("July 2026") for the recap prompt.
    static func monthLabel(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return fmt.string(from: date)
    }

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    private func uid() -> String? {
        @Shared(.user) var user
        return user?.id
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                analytics.log("memories_opened")
                // FL3-dismiss — hydrate the device-local "not memory-worthy" dismissals so waved-off cards
                // (and photos) stay hidden across launches. Reads @AppStorage; no Firestore.
                @Shared(.appStorage(Self.dismissedGroupsKey)) var dismissedGroupsRaw = ""
                @Shared(.appStorage(Self.dismissedAssetsKey)) var dismissedAssetsRaw = ""
                state.dismissedOnThisDayGroups = Self.decodeDismissals(dismissedGroupsRaw)
                state.dismissedOnThisDayAssets = Self.decodeDismissals(dismissedAssetsRaw)
                let now = date.now
                // FL3 — resolve photo authorization (no prompt) and, if we can read, load this-date
                // photos. Runs alongside the memory load; it's independent of the household.
                let onThisDay: Effect<Action> = .run { send in
                    let status = photoLibrary.authorizationStatus()
                    let auth = PhotoAuthState(status)
                    await send(.onThisDayAuthLoaded(auth))
                    guard auth == .ready else { return }
                    await send(.onThisDayPhotosLoaded(Self.fetchOnThisDay(now: now, photoLibrary: photoLibrary)))
                }
                guard let hid = hid() else { return onThisDay }
                state.isLoading = true
                // H2-ext — OFFLINE-FIRST INSTANT PAINT: seed the timeline from the SQLite mirror THIS FRAME
                // (no await), then keep it live via the observation stream; the one-shot Firestore read
                // below refreshes + writes through. Guarded so a re-navigation with fresh data isn't
                // clobbered.
                localCache.bootstrap()
                if state.memories.isEmpty {
                    let cached = localCache.memories(hid)
                    if !cached.isEmpty { state.memories = cached }
                }
                return .merge(
                    // H2-ext — reactive paint from the mirror: current snapshot immediately (incl. photos),
                    // then a fresh array after each Firestore write-through.
                    .run { send in
                        for await memories in localCache.observeMemories(hid) {
                            await send(.memoriesCacheHydrated(memories))
                        }
                    }
                    .cancellable(id: CancelID.observeMemoriesCache, cancelInFlight: true),
                    .run { send in
                        // nil = the Firestore read FAILED (offline): keep the cache, skip write-through.
                        async let memories = try? await persistence.memories(hid)
                        async let members = (try? await persistence.members(hid)) ?? []
                        await send(.loaded(memories: await memories, members: await members))
                    },
                    onThisDay
                )

            case let .loaded(memories, members):
                state.isLoading = false
                state.hasLoaded = true
                state.members = members
                // H2-ext — Firestore is authoritative only when it actually answered (memories != nil).
                // When nil (offline) the observation stream keeps driving the cache-painted timeline.
                guard let memories else { return .none }
                state.memories = memories
                // Write the fresh set through to the mirror (upsert present, delete missing) so next
                // cold-nav paints instantly and deletions propagate.
                let writeThrough: Effect<Action> = hid().map { hid in
                    .run { [memories] _ in localCache.upsertMemories(hid, memories) }
                } ?? .none
                return .merge(writeThrough, photosEffect(for: memories, have: state.photoCache))

            case let .memoriesCacheHydrated(memories):
                // H2-ext — instant/reactive paint from the SQLite mirror (newest-first). Sets the timeline
                // + loads its photos; after Firestore's write-through the cache re-emits the identical set,
                // so this is idempotent (no churn).
                state.memories = memories
                return photosEffect(for: memories, have: state.photoCache)

            case let .photosLoaded(map):
                state.photoCache.merge(map) { _, new in new }
                return .none

            case let .onThisDayAuthLoaded(auth):
                state.photoAuth = auth
                return .none

            case let .onThisDayPhotosLoaded(groups):
                state.onThisDayPhotos = groups
                guard !groups.isEmpty else { return .none }
                let total = groups.reduce(0) { $0 + $1.assets.count }
                analytics.log("onthisday_photos_shown", [
                    "years": String(groups.count),
                    "photos": String(total),
                ])
                // Load a thumbnail for each on-this-day asset (best-effort, deduped).
                let ids = groups.flatMap { $0.assets.map(\.id) }.filter { state.onThisDayThumbs[$0] == nil }
                guard !ids.isEmpty else { return .none }
                return .run { send in
                    var thumbs: [String: Data] = [:]
                    for id in ids where thumbs[id] == nil {
                        if let data = await photoLibrary.loadThumbnail(id, CGSize(width: 160, height: 160)) {
                            thumbs[id] = data
                        }
                    }
                    await send(.onThisDayThumbsLoaded(thumbs))
                }

            case let .onThisDayThumbsLoaded(map):
                state.onThisDayThumbs.merge(map) { _, new in new }
                return .none

            case .connectPhotosTapped:
                let now = date.now
                return .run { send in
                    let status = await photoLibrary.requestAccess()
                    let auth = PhotoAuthState(status)
                    await send(.onThisDayAuthLoaded(auth))
                    guard auth == .ready else { return }
                    await send(.onThisDayPhotosLoaded(Self.fetchOnThisDay(now: now, photoLibrary: photoLibrary)))
                }

            case let .makeMemoryFromOnThisDay(yearsAgo):
                guard let group = state.onThisDayPhotos.first(where: { $0.yearsAgo == yearsAgo }),
                      !group.assets.isEmpty else { return .none }
                // Honor any "Not this one" per-photo dismissals so a waved-off shot never lands in the page.
                let assetIDs = group.assets.map(\.id).filter { !state.dismissedOnThisDayAssets.contains($0) }
                guard !assetIDs.isEmpty else { return .none }
                // Date the new page to the day those photos were actually taken (fallback: the anchor).
                let memoryDate = group.assets.first?.creationDate ?? group.date
                let memory = Memory(date: memoryDate, createdBy: uid() ?? "")
                state.editor = MemoryEditorReducer.State(memory: memory, isEditing: false, members: state.members)
                analytics.log("onthisday_memory_made", [
                    "yearsAgo": String(yearsAgo),
                    "photos": String(assetIDs.count),
                ])
                // Reuse the editor's existing browse→memory load path (loadFullImage → downscale → slot);
                // Save then uploads through StorageClient exactly like a hand-picked memory.
                return .send(.editor(.presented(.libraryAssetsPicked(assetIDs))))

            case let .dismissOnThisDayGroup(yearsAgo):
                // Wave off a whole year's card. Key the dismissal off the ORIGINAL full photo set so it's
                // stable regardless of any per-photo removals, then write it through to @AppStorage.
                guard let group = state.onThisDayPhotos.first(where: { $0.yearsAgo == yearsAgo }) else { return .none }
                let signature = Self.onThisDayGroupSignature(group.assets.map(\.id))
                state.dismissedOnThisDayGroups.insert(signature)
                analytics.log("onthisday_group_dismissed", ["yearsAgo": String(yearsAgo)])
                @Shared(.appStorage(Self.dismissedGroupsKey)) var raw = ""
                $raw.withLock { $0 = Self.encodeDismissals(state.dismissedOnThisDayGroups) }
                return .none

            case let .dismissOnThisDayAsset(id):
                // "Not this one" — hide just this photo (keeps the good ones in the group).
                state.dismissedOnThisDayAssets.insert(id)
                analytics.log("onthisday_photo_dismissed")
                @Shared(.appStorage(Self.dismissedAssetsKey)) var raw = ""
                $raw.withLock { $0 = Self.encodeDismissals(state.dismissedOnThisDayAssets) }
                return .none

            case .captureMomentTapped:
                let memory = Memory(date: date.now, createdBy: uid() ?? "")
                state.editor = MemoryEditorReducer.State(memory: memory, isEditing: false, members: state.members)
                return .none

            case let .memoryTapped(memory):
                analytics.log("memory_opened")
                state.editor = MemoryEditorReducer.State(memory: memory, isEditing: true, members: state.members)
                return .none

            case .peopleTapped:
                analytics.log("people_opened")
                state.faceTagging = FaceTaggingReducer.State(members: state.members)
                return .none

            case .faceTagging:
                return .none

            case let .kidFilterSelected(id):
                state.selectedKidId = id
                analytics.log("memory_filter_applied", ["filter": id == nil ? "all" : "kid"])
                return .none

            case let .recapTapped(monthKey):
                // Re-tap while loading/ready is a no-op; a prior failure can be retried.
                if case .loading = state.recaps[monthKey] { return .none }
                if case .ready = state.recaps[monthKey] { return .none }
                let month = state.visibleMemories.first { Self.monthKey(for: $0.date) == monthKey }
                let label = month.map { Self.monthLabel(for: $0.date) } ?? "this month"
                let payload = state.visibleMemories
                    .filter { Self.monthKey(for: $0.date) == monthKey }
                    .map { memory -> MemoryRecapPayload in
                        let names = memory.kidMemberIds.compactMap { kid in
                            state.members.first { $0.id == kid }.map { firstName($0.name) }
                        }
                        return MemoryRecapPayload(
                            title: memory.title ?? "",
                            text: memory.plainStory,
                            milestone: memory.milestone ?? "",
                            kidNames: names,
                            date: MemoryRecapPayload.isoDay.string(from: memory.date)
                        )
                    }
                guard !payload.isEmpty else { return .none }
                state.recaps[monthKey] = .loading
                analytics.log("memory_month_recap", ["memories": String(payload.count)])
                return .run { send in
                    do {
                        let recap = try await memoryRecap.recap(label, payload)
                        await send(.recapLoaded(monthKey: monthKey, recap: recap))
                    } catch {
                        await send(.recapFailed(monthKey: monthKey))
                    }
                }

            case let .recapLoaded(monthKey, recap):
                state.recaps[monthKey] = .ready(recap)
                return .none

            case let .recapFailed(monthKey):
                state.recaps[monthKey] = .failed
                return .none

            case let .editor(.presented(.delegate(.didSave(milestone)))):
                // A save changed the timeline — reload it. If the page carried a milestone, raise the
                // marquee keepsake celebration (the biggest moment in the app).
                if let milestone {
                    state.milestoneCelebration = milestone
                    analytics.log("milestone_celebrated", ["tagged": milestone.kidName.isEmpty ? "0" : "1"])
                }
                return .send(.task)

            case .editor(.presented(.delegate(.didDelete))):
                // A delete changed the timeline — reload it.
                return .send(.task)

            case .milestoneCelebrationDismissed:
                state.milestoneCelebration = nil
                return .none

            case .editor:
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) {
            MemoryEditorReducer()
        }
        .ifLet(\.$faceTagging, action: \.faceTagging) {
            FaceTaggingReducer()
        }
    }
}

/// A person's first name for warm copy ("Oliver", "Famfis") — shared by the recap payload + views.
func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}

// MARK: - Milestone celebration (D2 — the marquee moment)

/// Everything the D2 ``MilestoneCelebration`` needs to fire when a memory tagged with a milestone is
/// saved — the tagged kid's first name + color + avatar and the milestone text. Built by the editor on
/// Save (it has the roster + tags in hand) and handed up via the ``MemoryEditorReducer/Action/Delegate``
/// so the parent Memories view can raise the full-screen keepsake. `color`/`avatar` fall back to warm
/// defaults when no kid is tagged (a family-wide milestone still deserves a party).
public struct MilestoneCelebrationRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kidName: String
    public let milestone: String
    public let color: MemberColor
    public let avatarSystemName: String

    public init(
        id: UUID = UUID(),
        kidName: String,
        milestone: String,
        color: MemberColor,
        avatarSystemName: String
    ) {
        self.id = id
        self.kidName = kidName
        self.milestone = milestone
        self.color = color
        self.avatarSystemName = avatarSystemName
    }

    /// Builds a request from a just-saved memory + the roster — resolving the first tagged kid for the
    /// color/avatar (warm marigold + star fallback for an untagged, family-wide milestone). Returns `nil`
    /// when the memory carries no milestone (so only real milestones throw the party).
    static func from(memory: Memory, members: [HouseholdMember]) -> MilestoneCelebrationRequest? {
        guard let milestone = memory.milestone?.trimmingCharacters(in: .whitespacesAndNewlines),
              !milestone.isEmpty else { return nil }
        let kid = members.first { memory.kidMemberIds.contains($0.id) }
        return MilestoneCelebrationRequest(
            kidName: kid.map { firstName($0.name) } ?? "",
            milestone: milestone,
            color: kid?.color ?? .marigold,
            avatarSystemName: kid?.avatarSystemName ?? "star.circle.fill"
        )
    }
}
