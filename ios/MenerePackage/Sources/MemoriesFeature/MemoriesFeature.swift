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
    @ObservableState
    public struct State: Equatable {
        public var memories: [Memory] = []
        public var members: [HouseholdMember] = []
        /// Photo + sticker bytes for the timeline, keyed by Storage path (light in-memory cache).
        public var photoCache: [String: Data] = [:]
        public var isLoading = false
        public var hasLoaded = false
        @Presents public var editor: MemoryEditorReducer.State?

        public init() {}
    }

    public enum Action: Equatable {
        case task
        case loaded(memories: [Memory], members: [HouseholdMember])
        case photosLoaded([String: Data])
        /// The Memories-tab button AND the Today quick-action both send this to open a fresh page.
        case captureMomentTapped
        case memoryTapped(Memory)
        case editor(PresentationAction<MemoryEditorReducer.Action>)
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.analytics) var analytics
    @Dependency(\.date) var date

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
