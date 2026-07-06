import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import PhotoLibraryClient
import PhotosUI
import StorageClient
import SwiftUI
import UIKit
import UserDomain

// MARK: - Photo slot

/// One photo on a scrapbook page while it's being edited. Carries either a **freshly picked** JPEG
/// (not yet uploaded) or an **existing** Storage path (edit mode), plus an optional die-cut sticker
/// lifted from that photo (`SubjectLifter`). Uploaded on Save.
struct MemoryPhotoSlot: Equatable, Identifiable, Sendable {
    let id: String
    /// A freshly picked/cropped JPEG, not yet uploaded (wins over `existingPhotoPath` for display).
    var photoData: Data?
    /// The Storage path of an already-uploaded photo (edit mode).
    var existingPhotoPath: String?
    /// A freshly lifted die-cut sticker PNG (from "Make it a sticker ✂️"), not yet uploaded.
    var stickerData: Data?
    /// The Storage path of an already-uploaded sticker (edit mode).
    var existingStickerPath: String?
    /// Vision subject-lift in flight.
    var isLifting: Bool = false
    /// `true` once a lift found no clean subject — the affordance shows a warm note.
    var stickerFailed: Bool = false

    var hasSticker: Bool { stickerData != nil || existingStickerPath != nil }
}

@Reducer
public struct MemoryEditorReducer {
    @ObservableState
    public struct State: Equatable {
        var memory: Memory
        let isEditing: Bool
        var members: [HouseholdMember]
        var slots: [MemoryPhotoSlot]
        /// Existing photo/sticker bytes loaded from Storage in edit mode, keyed by path (for display).
        var loadedImages: [String: Data] = [:]
        var isSaving = false
        /// FL1 — the rich in-app photo browser (`PhotoLibraryBrowser`) sheet is up.
        var showLibraryBrowser = false
        /// FL1 — how many browser-picked assets are still loading their full image (for a gentle busy hint).
        var loadingLibraryCount = 0

        public init(memory: Memory, isEditing: Bool, members: [HouseholdMember]) {
            self.memory = memory
            self.isEditing = isEditing
            self.members = members
            // Seed the editor slots from the memory's existing photos/stickers (edit mode). Stickers are
            // matched to photos positionally where present.
            self.slots = memory.photoPaths.enumerated().map { index, path in
                MemoryPhotoSlot(
                    id: "slot-\(index)-\(path)",
                    existingPhotoPath: path,
                    existingStickerPath: index < memory.stickerPaths.count ? memory.stickerPaths[index] : nil
                )
            }
        }

        /// The bytes to render for a slot's photo: a fresh pick wins over the loaded existing one.
        func photoData(for slot: MemoryPhotoSlot) -> Data? {
            if let d = slot.photoData { return d }
            if let p = slot.existingPhotoPath { return loadedImages[p] }
            return nil
        }

        /// The bytes to render for a slot's sticker.
        func stickerData(for slot: MemoryPhotoSlot) -> Data? {
            if let d = slot.stickerData { return d }
            if let p = slot.existingStickerPath { return loadedImages[p] }
            return nil
        }

        /// The kids (Oliver / Famfis) + adults offered as tagging chips.
        var taggableMembers: [HouseholdMember] { members }

        /// The age-appropriate developmental milestones (from ``ChildCareKB``) offered as picker chips —
        /// derived from the currently-tagged kids' birthdates, de-duplicated across kids. Empty until a
        /// kid with a known birthday is tagged (so the loop only surfaces when it's relevant). Closes the
        /// MILESTONE↔JOURNAL loop: tapping one stamps a recognizable value onto `memory.milestone`.
        var kbMilestoneSuggestions: [ChildCareKB.LoggableMilestone] {
            let taggedKids = members.filter { memory.kidMemberIds.contains($0.id) }
            var seen = Set<String>()
            var result: [ChildCareKB.LoggableMilestone] = []
            for kid in taggedKids {
                guard let months = kid.ageInMonths() else { continue }
                for m in ChildCareKB.loggableMilestones(ageInMonths: months) where seen.insert(m.tag.lowercased()).inserted {
                    result.append(m)
                }
            }
            return result
        }

        /// Enough to save: a story, a title, or at least one photo.
        var canSave: Bool {
            !memory.plainStory.isEmpty
                || !slots.isEmpty
                || !(memory.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case cancelTapped
        case membersLoaded([HouseholdMember])
        case imagesLoaded([String: Data])
        case photoAdded(Data)
        case libraryBrowseTapped
        case libraryAssetsPicked([String])
        case libraryLoadFinishedOne
        case removeSlot(id: String)
        case makeStickerTapped(id: String)
        case stickerLifted(id: String, Data?)
        case toggleKid(String)
        case milestoneChipTapped(String)
        case saveTapped
        case deleteTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable {
            case didSave
            case didDelete(id: String)
        }
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss
    @Dependency(\.persistence) var persistence
    @Dependency(\.storage) var storage
    @Dependency(\.analytics) var analytics
    @Dependency(\.date) var date
    @Dependency(\.photoLibrary) var photoLibrary

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    private func uid() -> String? {
        @Shared(.user) var user
        return user?.id
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Edit mode: fetch existing photo + sticker bytes for display (best-effort). Also load
                // the roster if it's empty (e.g. opened straight from the Today quick-action before the
                // Memories tab's own load ran) so the kid-tagging chips always appear.
                let paths = (state.memory.photoPaths + state.memory.stickerPaths).filter { !$0.isEmpty }
                let needsMembers = state.members.isEmpty
                guard !paths.isEmpty || needsMembers else { return .none }
                let hid = hid()
                return .run { send in
                    if needsMembers, let hid {
                        let members = (try? await persistence.members(hid)) ?? []
                        if !members.isEmpty { await send(.membersLoaded(members)) }
                    }
                    if !paths.isEmpty {
                        var loaded: [String: Data] = [:]
                        for path in paths where loaded[path] == nil {
                            // H1: cached pipeline (memory+disk, deduped).
                            if let data = try? await ImagePipeline.shared.data(
                                forStoragePath: path,
                                loader: { try await storage.downloadData(path) }
                            ) { loaded[path] = data }
                        }
                        await send(.imagesLoaded(loaded))
                    }
                }

            case let .membersLoaded(members):
                state.members = members
                return .none

            case .cancelTapped:
                return .run { _ in await dismiss() }

            case let .imagesLoaded(map):
                state.loadedImages.merge(map) { _, new in new }
                return .none

            case let .photoAdded(data):
                let index = state.slots.count
                state.slots.append(MemoryPhotoSlot(id: "new-\(index)-\(UUID().uuidString)", photoData: data))
                return .none

            case .libraryBrowseTapped:
                state.showLibraryBrowser = true
                return .none

            case let .libraryAssetsPicked(assetIDs):
                // FL1: the family picked assets in the rich browser. Load each full image off the
                // library and feed it through the SAME `photoAdded` path the PhotosPicker uses — the
                // bytes are downscaled/JPEG'd (like PhotoCaptureField) before they become slots, so the
                // existing Save→upload path is unchanged.
                guard !assetIDs.isEmpty else { return .none }
                state.showLibraryBrowser = false
                state.loadingLibraryCount += assetIDs.count
                return .run { send in
                    for id in assetIDs {
                        var jpeg: Data?
                        if let data = await photoLibrary.loadFullImage(id),
                           let ui = UIImage(data: data) {
                            jpeg = CaptureImageProcessing.downscaledJPEG(from: ui) ?? data
                        }
                        if let jpeg { await send(.photoAdded(jpeg)) }
                        await send(.libraryLoadFinishedOne)
                    }
                }

            case .libraryLoadFinishedOne:
                state.loadingLibraryCount = max(0, state.loadingLibraryCount - 1)
                return .none

            case let .removeSlot(id):
                state.slots.removeAll { $0.id == id }
                return .none

            case let .makeStickerTapped(id):
                guard let idx = state.slots.firstIndex(where: { $0.id == id }),
                      !state.slots[idx].isLifting,
                      let source = state.photoData(for: state.slots[idx]) else { return .none }
                state.slots[idx].isLifting = true
                state.slots[idx].stickerFailed = false
                return .run { send in
                    var sticker: Data?
                    if let ui = UIImage(data: source), let lifted = await SubjectLifter.liftSticker(from: ui) {
                        sticker = lifted.pngData()
                    }
                    await send(.stickerLifted(id: id, sticker))
                }

            case let .stickerLifted(id, data):
                guard let idx = state.slots.firstIndex(where: { $0.id == id }) else { return .none }
                state.slots[idx].isLifting = false
                if let data {
                    state.slots[idx].stickerData = data
                } else {
                    state.slots[idx].stickerFailed = true
                }
                return .none

            case let .toggleKid(memberID):
                if let i = state.memory.kidMemberIds.firstIndex(of: memberID) {
                    state.memory.kidMemberIds.remove(at: i)
                } else {
                    state.memory.kidMemberIds.append(memberID)
                }
                return .none

            case let .milestoneChipTapped(tag):
                // Toggle: tapping the active milestone clears it.
                state.memory.milestone = (state.memory.milestone == tag) ? nil : tag
                return .none

            case .saveTapped:
                guard let hid = hid(), state.canSave, !state.isSaving else { return .none }
                state.isSaving = true
                var memory = state.memory
                if memory.createdBy.isEmpty { memory.createdBy = uid() ?? "" }
                memory.title = memory.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                memory.milestone = memory.milestone?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                memory.updatedAt = date.now
                let finalized = memory
                let slots = state.slots
                let isEditing = state.isEditing
                return .run { send in
                    var toSave = finalized
                    var photoPaths: [String] = []
                    var stickerPaths: [String] = []
                    for (index, slot) in slots.enumerated() {
                        // Photo: upload a freshly picked one; otherwise keep the existing path.
                        if let jpeg = slot.photoData {
                            if let path = try? await storage.uploadMemoryPhoto(hid, toSave.id, index, jpeg) {
                                photoPaths.append(path)
                            }
                        } else if let existing = slot.existingPhotoPath {
                            photoPaths.append(existing)
                        }
                        // Sticker: upload a freshly lifted one; otherwise keep the existing path.
                        if let png = slot.stickerData {
                            if let path = try? await storage.uploadMemorySticker(hid, toSave.id, index, png) {
                                stickerPaths.append(path)
                            }
                        } else if let existing = slot.existingStickerPath {
                            stickerPaths.append(existing)
                        }
                    }
                    toSave.photoPaths = photoPaths
                    toSave.stickerPaths = stickerPaths
                    try await persistence.saveMemory(hid, toSave)
                    analytics.log("memory_created", ["editing": isEditing ? "1" : "0"])
                    if let milestone = toSave.milestone, !milestone.isEmpty {
                        analytics.log("milestone_logged", ["kids": String(toSave.kidMemberIds.count)])
                    }
                    await send(.delegate(.didSave))
                    await dismiss()
                }

            case .deleteTapped:
                guard let hid = hid() else { return .none }
                let id = state.memory.id
                let cleanup = (state.memory.photoPaths + state.memory.stickerPaths).filter { !$0.isEmpty }
                return .run { send in
                    try await persistence.deleteMemory(hid, id)
                    if !cleanup.isEmpty { try? await storage.deletePaths(cleanup) }
                    await send(.delegate(.didDelete(id: id)))
                    await dismiss()
                }

            case .delegate, .binding:
                return .none
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
