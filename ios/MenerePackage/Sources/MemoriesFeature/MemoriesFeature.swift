import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import StorageClient
import UserDomain

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
        @Presents public var editor: MemoryEditorReducer.State?

        public init() {}

        /// Memories after applying the active per-kid filter (newest-first order preserved).
        public var visibleMemories: [Memory] {
            guard let id = selectedKidId else { return memories }
            return memories.filter { $0.kidMemberIds.contains(id) }
        }

        /// Memories whose date lands ~1 year ago (within ±3 weeks), honoring the active filter —
        /// the "This time last year 💛" resurfacing. Empty (so the section hides) when none.
        public var thisTimeLastYear: [Memory] {
            let cal = Calendar.current
            let now = Date()
            guard let anchor = cal.date(byAdding: .year, value: -1, to: now) else { return [] }
            let window: TimeInterval = 21 * 24 * 60 * 60 // ±3 weeks
            return visibleMemories.filter { abs($0.date.timeIntervalSince(anchor)) <= window }
        }
    }

    public enum Action: Equatable {
        case task
        case loaded(memories: [Memory], members: [HouseholdMember])
        case photosLoaded([String: Data])
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
                guard let hid = hid() else { return .none }
                state.isLoading = true
                return .run { send in
                    async let memories = (try? await persistence.memories(hid)) ?? []
                    async let members = (try? await persistence.members(hid)) ?? []
                    await send(.loaded(memories: await memories, members: await members))
                }

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
                        if let data = try? await storage.downloadData(path) { loaded[path] = data }
                    }
                    await send(.photosLoaded(loaded))
                }

            case let .photosLoaded(map):
                state.photoCache.merge(map) { _, new in new }
                return .none

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
