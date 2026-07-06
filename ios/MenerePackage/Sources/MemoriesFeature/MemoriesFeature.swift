import AnalyticsClient
import ComposableArchitecture
import CoreGraphics
import FamilyDomain
import Foundation
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
        @Presents public var editor: MemoryEditorReducer.State?

        public init() {}

        /// Memories after applying the active per-kid filter (newest-first order preserved).
        public var visibleMemories: [Memory] {
            guard let id = selectedKidId else { return memories }
            return memories.filter { $0.kidMemberIds.contains(id) }
        }

    }

    public enum Action: Equatable {
        case task
        case loaded(memories: [Memory], members: [HouseholdMember])
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
        /// The Memories-tab button AND the Today quick-action both send this to open a fresh page.
        case captureMomentTapped
        case memoryTapped(Memory)
        /// A filter chip was tapped (`nil` = "All").
        case kidFilterSelected(String?)
        /// "Recap this month ✨" tapped on a month header (keyed by month bucket "yyyy-M").
        case recapTapped(monthKey: String)
        case recapLoaded(monthKey: String, recap: String)
        case recapFailed(monthKey: String)
        case editor(PresentationAction<MemoryEditorReducer.Action>)
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.analytics) var analytics
    @Dependency(\.memoryRecap) var memoryRecap
    @Dependency(\.date) var date
    @Dependency(\.photoLibrary) var photoLibrary

    /// FL3 — how many prior years back to look for "On this day" photos + memories.
    static let onThisDayYearSpan = 5
    /// FL3 — ± window (in calendar days) around today's day when matching this-date-across-years.
    static let onThisDayWindowDays = 1

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
                return .merge(
                    .run { send in
                        async let memories = (try? await persistence.memories(hid)) ?? []
                        async let members = (try? await persistence.members(hid)) ?? []
                        await send(.loaded(memories: await memories, members: await members))
                    },
                    onThisDay
                )

            case let .loaded(memories, members):
                state.isLoading = false
                state.hasLoaded = true
                state.memories = memories
                state.members = members
                // Fetch every page's photos + stickers into the cache (best-effort).
                let paths = memories.flatMap { $0.photoPaths + $0.stickerPaths }.filter { !$0.isEmpty }
                let missing = paths.filter { state.photoCache[$0] == nil }
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
                let assetIDs = group.assets.map(\.id)
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

            case .captureMomentTapped:
                let memory = Memory(date: date.now, createdBy: uid() ?? "")
                state.editor = MemoryEditorReducer.State(memory: memory, isEditing: false, members: state.members)
                return .none

            case let .memoryTapped(memory):
                analytics.log("memory_opened")
                state.editor = MemoryEditorReducer.State(memory: memory, isEditing: true, members: state.members)
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

            case .editor(.presented(.delegate(.didSave))),
                 .editor(.presented(.delegate(.didDelete))):
                // A save/delete changed the timeline — reload it.
                return .send(.task)

            case .editor:
                return .none
            }
        }
        .ifLet(\.$editor, action: \.editor) {
            MemoryEditorReducer()
        }
    }
}

/// A person's first name for warm copy ("Oliver", "Famfis") — shared by the recap payload + views.
func firstName(_ name: String) -> String {
    name.split(separator: " ").first.map(String.init) ?? name
}
