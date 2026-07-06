import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import HouseFeature
import HueClient
import MenereUI
import PersistenceClient
import StorageClient
import SwiftUI
import UserDomain

@Reducer
public struct ChoresReducer {
    @ObservableState
    public struct State: Equatable {
        var chores: [Chore] = []
        var members: [HouseholdMember] = []
        var stats: [MemberStats] = []
        var rewards: [Reward] = []
        var activity: [ActivityItem] = []
        // P8 — House care: recurring upkeep, no XP, tracked by who-did-it-last. P9 adds plant
        // `CareItem`s (kind == .plant) into the same array — the view splits them into sections.
        var careItems: [CareItem] = []
        /// P29 — the household's home-maintenance profile (`config/homeProfile`), or nil until the
        /// user sets it up. Gates the House-care "home maintenance" entry (setup vs. suggested list)
        /// and feeds the readiness score.
        var homeProfile: HomeProfile?
        /// Plant photo bytes, keyed by Storage `photoPath` (light in-memory cache; mirrors the docs
        /// page cache). Loaded after `careItems` land so plant rows render a real thumbnail.
        var carePhotos: [String: Data] = [:]
        /// Family-Brain documents (P10) — loaded one-shot alongside care items so a pet's row can show
        /// a terracotta expiry chip when a linked doc (e.g. a rabies cert) is expiring or past due.
        var documents: [FamilyDomain.Document] = []
        /// In-memory only: the starter-suggestions card comes back on relaunch (acceptable for a
        /// private app; persisting the dismissal is a possible later polish).
        var careSuggestionsDismissed = false
        /// Same, for the Yard & garden seasonal-starters card (P9-C3).
        var yardSuggestionsDismissed = false
        /// Same, for the Pets "The pack" starter card (P10).
        var petSuggestionsDismissed = false
        /// P28 — the pending "care marked done" undo for the Home pets/plants roster. Set by
        /// ``Action/markCareTaskDone`` on a plant/pet one-tap completion; captures the task's PRIOR
        /// done-stamp so the overview's Undo banner can name the task and truly reverse the write via
        /// the same `saveCareItem` path. Nil = no banner showing.
        var careUndo: CareUndo?

        /// Captured context + prior done-stamp for a one-tap care completion, so the overview's Undo
        /// banner can name the exact task and restore it (not merely re-toggle). See ``careUndo``.
        struct CareUndo: Equatable {
            var itemID: String
            var taskID: String
            var itemName: String
            var taskTitle: String
            var priorLastDoneAt: Date?
            var priorLastDoneBy: String?
            /// The optimistic activity entry inserted by the mark-done, popped back out on Undo.
            var activityID: String?
            /// Bumped per mark-done so the banner re-animates and restarts its auto-dismiss timer.
            var nonce: Int
        }
        var isLoading = false
        @Presents var form: ChoreFormReducer.State?
        @Presents var careForm: CareItemFormReducer.State?
        /// P29 — the Home-maintenance sheet (setup form + season-suggested library → materialize).
        @Presents var homeMaintenance: HomeMaintenanceReducer.State?
        /// P9.1 — the Planta-inspired add-a-plant capture wizard. ADD routes here; EDIT stays on
        /// ``careForm``.
        @Presents var plantCapture: PlantCaptureReducer.State?
        /// P19-C3 — the per-plant AI "troubleshoot" sheet, presented from a plant's DETAIL screen.
        @Presents var troubleshoot: PlantTroubleshootReducer.State?
        // Simple add-reward entry
        var showAddReward = false
        var newRewardTitle = ""
        var newRewardCost = 50
        // Confetti celebration: bumped when the live leaderboard reports a member's level rising;
        // `confettiColor` is that member's color (drives ``ConfettiBurst`` in ``ChoresView``).
        var confettiTrigger = 0
        var confettiColor: MemberColor?

        /// P16-C2 — the ritual key currently firing from the Smart-home preview's inline chips (dims the
        /// tapped chip while the scene recall is in flight). Nil = idle.
        var recallingRitual: String?

        /// P16 — backing store for the hub's **Smart home** overview card: loads the same Hue/Lutron/
        /// etc. data Today's "The house" card uses, so the card can seed the shared ``HouseView``.
        public var houseCard = HouseCardReducer.State()

        public init() {}

        func stats(for memberID: String) -> MemberStats {
            stats.first { $0.memberID == memberID } ?? MemberStats(id: memberID, memberID: memberID)
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded(chores: [Chore], members: [HouseholdMember], stats: [MemberStats], rewards: [Reward], activity: [ActivityItem], careItems: [CareItem], documents: [FamilyDomain.Document])
        case statsUpdated([MemberStats])
        case addTapped
        case editTapped(Chore)
        case toggleComplete(Chore)
        case addRewardTapped
        case createReward
        case redeem(Reward, byMemberID: String)
        // P8 — House care
        case addCareItemTapped
        // P29 — Home maintenance
        case homeProfileLoaded(HomeProfile?)
        case homeMaintenanceTapped
        case homeMaintenance(PresentationAction<HomeMaintenanceReducer.Action>)
        case editCareItemTapped(CareItem)
        case markCareTaskDone(itemID: String, taskID: String)
        /// P28 — restore the last one-tap care completion to its prior done-stamp (the overview's Undo).
        case undoCareTaskDone
        /// P28 — dismiss the care-undo banner without reversing (tap-away / auto-timeout).
        case dismissCareUndo
        /// P19-C2 — batch "water this room": mark the due Water task done for every plant in `location`
        /// (nil ⇒ the "no room yet" bucket) whose water is due, each via the shared ``CareCompletion``/
        /// `writeCareDone` path (server-consistent, one activity entry per plant).
        case waterRoomDone(location: String?)
        case careSuggestionTapped(CareSuggestion)
        case dismissCareSuggestions
        // P9-C3 — Yard & garden (kind == .zone)
        case addYardZoneTapped
        case yardSuggestionTapped(YardSuggestion)
        case dismissYardSuggestions
        // P9 — Plants
        case addPlantTapped
        // P10 — Pets (kind == .pet)
        case addPetTapped
        case petSuggestionTapped(PetSuggestion)
        case dismissPetSuggestions
        // P31 — Pet care schedules (PetCareKB). Setup section on a pet's DETAIL screen.
        /// Logged once the setup section is expanded on a pet's detail — `pet_schedule_setup`.
        case petScheduleSetupOpened(petID: String)
        /// Materialize a ``PetCareKB`` recommendation into the pet's own ``CareTask`` list. `alreadyDone`
        /// backdates it to caught-up (the "I already do this" path); otherwise it lands due-today.
        case materializePetCareTask(petID: String, templateID: String, alreadyDone: Bool)
        // P31 — Plant care schedules (PlantCareKB). Smart per-species "Recommended schedule" section on a
        // plant's DETAIL screen.
        /// Logged once the recommended-schedule section is expanded on a plant's detail — `plant_schedule_setup`.
        case plantScheduleSetupOpened(plantID: String)
        /// Materialize a ``PlantCareKB`` recommendation into the plant's own ``CareTask`` list. `alreadyDone`
        /// backdates it to caught-up (the "I already do this" path); otherwise it lands due-today.
        case materializePlantCareTask(plantID: String, templateID: String, alreadyDone: Bool)
        case carePhotosLoaded([String: Data])
        // P19-C3 — open the AI troubleshoot sheet for a plant (from its DETAIL screen).
        case openTroubleshoot(plantID: String)
        // P16-C2 — fire a Hue ritual (Bedtime / Dinner's ready) inline from the Smart-home preview.
        case recallRitual(HueRitual)
        case ritualRecallFinished(key: String)
        case form(PresentationAction<ChoreFormReducer.Action>)
        case careForm(PresentationAction<CareItemFormReducer.Action>)
        case plantCapture(PresentationAction<PlantCaptureReducer.Action>)
        case troubleshoot(PresentationAction<PlantTroubleshootReducer.Action>)
        case houseCard(HouseCardReducer.Action)
        case binding(BindingAction<State>)
    }

    private enum CancelID { case observeStats, careUndo }

    public init() {}

    private func ctx() -> (hid: String, uid: String)? {
        @Shared(.user) var user
        guard let hid = user?.householdId, let uid = user?.id else { return nil }
        return (hid, uid)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.houseCard, action: \.houseCard) { HouseCardReducer() }
        Reduce { state, action in
            @Dependency(\.analytics) var analytics   // P25 telemetry (fire-and-forget)
            switch action {
            case .task:
                guard let (hid, _) = ctx() else { return .none }
                state.isLoading = true
                return .merge(
                    // Smart-home card data (independent; hides itself when Hue isn't configured).
                    .send(.houseCard(.load)),
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        async let chores = persistence.chores(hid)
                        async let members = persistence.members(hid)
                        async let stats = persistence.memberStats(hid)
                        async let rewards = persistence.rewards(hid)
                        async let activity = persistence.activity(hid)
                        async let careItems = persistence.careItems(hid)
                        async let documents = persistence.documents(hid)
                        await send(.loaded(
                            chores: (try? await chores) ?? [],
                            members: (try? await members) ?? [],
                            stats: (try? await stats) ?? [],
                            rewards: (try? await rewards) ?? [],
                            activity: (try? await activity) ?? [],
                            careItems: (try? await careItems) ?? [],
                            documents: (try? await documents) ?? []
                        ))
                    },
                    // P29 — the home-maintenance profile (cheap gate; independent of the rest).
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        await send(.homeProfileLoaded((try? await persistence.homeProfile(hid)) ?? nil))
                    },
                    // Leaderboard updates live as the server-side XP trigger writes stats.
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        for await stats in persistence.observeMemberStats(hid) {
                            await send(.statsUpdated(stats))
                        }
                    }
                    .cancellable(id: CancelID.observeStats, cancelInFlight: true)
                )

            case let .loaded(chores, members, stats, rewards, activity, careItems, documents):
                state.isLoading = false
                state.documents = documents
                state.chores = chores.sorted {
                    $0.isCompleted == $1.isCompleted ? $0.createdAt < $1.createdAt : (!$0.isCompleted && $1.isCompleted)
                }
                state.members = members
                state.stats = stats
                state.rewards = rewards.sorted { $0.xpCost < $1.xpCost }
                state.activity = activity
                state.careItems = Self.sortedCare(careItems)
                // Fetch plant photos + die-cut stickers (kind-agnostic: any care item with a
                // photoPath / stickerPath) into the cache, keyed by Storage path.
                let photoPaths = (careItems.compactMap(\.photoPath)
                    + careItems.compactMap(\.stickerPath)).filter { !$0.isEmpty }
                guard !photoPaths.isEmpty else { return .none }
                return .run { send in
                    @Dependency(\.storage) var storage
                    var loaded: [String: Data] = [:]
                    for path in photoPaths where loaded[path] == nil {
                        // H1: route through the shared cached pipeline (memory+disk, deduped) so a
                        // re-appearance of the Home tab does NOT re-download care/plant/pet photos.
                        if let data = try? await ImagePipeline.shared.data(
                            forStoragePath: path,
                            loader: { try await storage.downloadData(path) }
                        ) { loaded[path] = data }
                    }
                    await send(.carePhotosLoaded(loaded))
                }

            case let .carePhotosLoaded(map):
                state.carePhotos.merge(map) { _, new in new }
                return .none

            case let .openTroubleshoot(plantID):
                guard let plant = state.careItems.first(where: { $0.id == plantID }) else { return .none }
                // Snapshot the plant's identity + situation + current watering cadence for the model.
                let waterInterval = plant.tasks
                    .first { PlantCarePreset.matching($0.title) == .water }?.intervalDays
                state.troubleshoot = PlantTroubleshootReducer.State(
                    plantID: plant.id,
                    plantName: plant.name,
                    species: plant.species,
                    commonName: plant.speciesLatin,
                    careContext: plant.careContext,
                    currentWaterIntervalDays: waterInterval
                )
                return .none

            case let .troubleshoot(.presented(.delegate(.updateWaterInterval(itemID, days)))):
                // The context-adaptive payoff: apply the AI's suggested watering cadence to the plant's
                // Water task and persist (server-consistent via saveCareItem). Best-effort — the sheet
                // already showed the "updated" confirmation optimistically.
                guard let (hid, _) = ctx(),
                      let i = state.careItems.firstIndex(where: { $0.id == itemID }),
                      let taskIdx = state.careItems[i].tasks.firstIndex(where: {
                          PlantCarePreset.matching($0.title) == .water
                      })
                else { return .none }
                state.careItems[i].tasks[taskIdx].intervalDays = days
                state.careItems = Self.sortedCare(state.careItems)
                let toSave = state.careItems.first { $0.id == itemID }
                return .run { _ in
                    guard let toSave else { return }
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, toSave)
                }

            case let .statsUpdated(stats):
                // Level-up celebration: fire only when a member we already had stats for rises a
                // level (skips the initial snapshot, where no prior stat exists to compare against).
                for updated in stats {
                    if let prior = state.stats.first(where: { $0.memberID == updated.memberID }),
                       updated.level > prior.level {
                        state.confettiColor = state.members.first { $0.id == updated.memberID }?.color
                        state.confettiTrigger += 1
                    }
                }
                state.stats = stats
                return .none

            case .addTapped:
                state.form = ChoreFormReducer.State(chore: Chore(title: ""), isEditing: false, members: state.members)
                return .none

            case let .editTapped(chore):
                state.form = ChoreFormReducer.State(chore: chore, isEditing: true, members: state.members)
                return .none

            case let .toggleComplete(chore):
                guard let (hid, uid) = ctx(),
                      let idx = state.chores.firstIndex(where: { $0.id == chore.id }) else { return .none }
                // Shared completion logic (see ``ChoreCompletion``) so Today and Chores behave
                // identically. XP is reversed/awarded server-side by onChoreToggled either way.
                if !chore.isCompleted { analytics.log("chore_completed") }
                let outcome = chore.isCompleted
                    ? ChoreCompletion.uncomplete(chore)
                    : ChoreCompletion.complete(chore, fallbackCreditID: uid, members: state.members)
                state.chores[idx] = outcome.updated
                if let next = outcome.next { state.chores.append(next) }        // recurring respawn
                if let activity = outcome.activity { state.activity.insert(activity, at: 0) }
                return .run { [outcome] _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.writeCompletion(hid: hid, outcome)
                }

            case .addRewardTapped:
                state.newRewardTitle = ""
                state.newRewardCost = 50
                state.showAddReward = true
                return .none

            case .createReward:
                let title = state.newRewardTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let (hid, _) = ctx() else { return .none }
                let reward = Reward(title: title, xpCost: max(1, state.newRewardCost))
                state.rewards.append(reward)
                state.rewards.sort { $0.xpCost < $1.xpCost }
                state.showAddReward = false
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveReward(hid, reward)
                }

            case let .redeem(reward, memberID):
                guard let (hid, _) = ctx() else { return .none }
                var stats = state.stats(for: memberID)
                guard stats.totalXP >= reward.xpCost else { return .none }
                stats.totalXP -= reward.xpCost
                stats.level = XPCalculator.level(forTotalXP: stats.totalXP)
                stats.updatedAt = Date()
                apply(stats, to: &state.stats)
                let redemption = RewardRedemption(
                    rewardID: reward.id, rewardTitle: reward.title,
                    memberID: memberID, xpCost: reward.xpCost
                )
                let savedStats = stats
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveMemberStats(hid, savedStats)
                    try await persistence.saveRedemption(hid, redemption)
                }

            case .addCareItemTapped:
                state.careForm = CareItemFormReducer.State(
                    item: CareItem(name: "", tasks: [CareTask(title: "")]),
                    isEditing: false
                )
                return .none

            case let .homeProfileLoaded(profile):
                state.homeProfile = profile
                return .none

            case .homeMaintenanceTapped:
                state.homeMaintenance = HomeMaintenanceReducer.State(
                    profile: state.homeProfile,
                    careItems: state.careItems
                )
                return .none

            case .homeMaintenance(.presented(.delegate(.didChange))):
                // A profile save or a materialize wrote to Firestore — reload care + profile so the
                // House-care banner, score, and rows reflect it.
                return .send(.task)

            case .addPlantTapped:
                analytics.log("plant_capture_started")
                // P9.1 — ADD now opens the Planta-inspired capture wizard (photo → identify → nickname →
                // home → watering → welcome). EDIT still uses ``careForm``. Seed the Home step's chips
                // with the family's existing care-item locations.
                let locations = state.careItems.compactMap { $0.location?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                state.plantCapture = PlantCaptureReducer.State(existingLocations: locations)
                return .none

            case let .editCareItemTapped(item):
                state.careForm = CareItemFormReducer.State(item: item, isEditing: true)
                return .none

            case let .markCareTaskDone(itemID, taskID):
                guard let (hid, uid) = ctx(),
                      let i = state.careItems.firstIndex(where: { $0.id == itemID }),
                      let ti = state.careItems[i].tasks.firstIndex(where: { $0.id == taskID }),
                      let outcome = CareCompletion.markDone(
                          item: state.careItems[i], taskID: taskID, byMemberID: uid, members: state.members
                      )
                else { return .none }
                let kind = state.careItems[i].kind
                // Capture the task's PRIOR done-stamp BEFORE we overwrite it, so the roster's Undo can
                // truly restore it (not just re-toggle to "now").
                let priorAt = state.careItems[i].tasks[ti].lastDoneAt
                let priorBy = state.careItems[i].tasks[ti].lastDoneBy
                let taskTitle = state.careItems[i].tasks[ti].title
                let itemName = state.careItems[i].name
                analytics.log("care_marked_done", ["kind": kind.rawValue])
                // Shared care-completion logic (see ``CareCompletion``) so Today and Home behave
                // identically: stamp who-did-it-last + a best-effort "took care of…" activity entry.
                state.careItems[i] = outcome.updated
                if let activity = outcome.activity { state.activity.insert(activity, at: 0) }
                var effects: [Effect<Action>] = [
                    .run { [outcome] _ in
                        @Dependency(\.persistence) var persistence
                        try await persistence.writeCareDone(hid: hid, outcome)
                    }
                ]
                // The Home pets/plants ROSTER offers a one-tap mark-done; back it with a labeled Undo
                // banner (legibility + reversibility). House/zone upkeep isn't rostered that way — leave
                // it be so its behavior is unchanged.
                if kind == .plant || kind == .pet {
                    state.careUndo = State.CareUndo(
                        itemID: itemID, taskID: taskID, itemName: itemName, taskTitle: taskTitle,
                        priorLastDoneAt: priorAt, priorLastDoneBy: priorBy,
                        activityID: outcome.activity?.id, nonce: (state.careUndo?.nonce ?? 0) + 1
                    )
                    effects.append(
                        .run { send in
                            try await Task.sleep(for: .seconds(6))
                            await send(.dismissCareUndo)
                        }
                        .cancellable(id: CancelID.careUndo, cancelInFlight: true)
                    )
                }
                return .merge(effects)

            case .undoCareTaskDone:
                guard let (hid, _) = ctx(), let undo = state.careUndo,
                      let i = state.careItems.firstIndex(where: { $0.id == undo.itemID }),
                      let ti = state.careItems[i].tasks.firstIndex(where: { $0.id == undo.taskID })
                else {
                    state.careUndo = nil
                    return .cancel(id: CancelID.careUndo)
                }
                analytics.log("care_marked_done_undone", ["kind": state.careItems[i].kind.rawValue])
                // Restore the exact task's prior done-stamp, pop the optimistic activity entry, and write
                // the restored item back through the same `saveCareItem` path the completion used.
                state.careItems[i].tasks[ti].lastDoneAt = undo.priorLastDoneAt
                state.careItems[i].tasks[ti].lastDoneBy = undo.priorLastDoneBy
                let undoneActivityID = undo.activityID
                if let aid = undoneActivityID { state.activity.removeAll { $0.id == aid } }
                let restored = state.careItems[i]
                state.careUndo = nil
                return .merge(
                    .cancel(id: CancelID.careUndo),
                    .run { _ in
                        @Dependency(\.persistence) var persistence
                        try await persistence.saveCareItem(hid, restored)
                        // Also delete the optimistic activity doc the mark-done wrote, so a stale
                        // "watered …" entry doesn't linger in Firestore. Best-effort — never surface.
                        if let aid = undoneActivityID {
                            try? await persistence.deleteActivity(hid, aid)
                        }
                    }
                )

            case .dismissCareUndo:
                state.careUndo = nil
                return .cancel(id: CancelID.careUndo)

            case let .waterRoomDone(location):
                guard let (hid, uid) = ctx() else { return .none }
                // Normalize both sides so a trimmed/empty location matches the same "no room" bucket the
                // roster groups on.
                let target = location?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
                var outcomes: [CareCompletion.Outcome] = []
                for i in state.careItems.indices {
                    let item = state.careItems[i]
                    guard item.kind == .plant else { continue }
                    let itemRoom = item.location?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    guard itemRoom == target else { continue }
                    guard let water = item.tasks.first(where: {
                        PlantCarePreset.matching($0.title) == .water && $0.isDue()
                    }) else { continue }
                    guard let outcome = CareCompletion.markDone(
                        item: state.careItems[i], taskID: water.id, byMemberID: uid, members: state.members
                    ) else { continue }
                    state.careItems[i] = outcome.updated
                    if let activity = outcome.activity { state.activity.insert(activity, at: 0) }
                    outcomes.append(outcome)
                }
                guard !outcomes.isEmpty else { return .none }
                return .run { [outcomes] _ in
                    @Dependency(\.persistence) var persistence
                    for outcome in outcomes { try await persistence.writeCareDone(hid: hid, outcome) }
                }

            case let .careSuggestionTapped(suggestion):
                guard let (hid, _) = ctx() else { return .none }
                let item = suggestion.makeItem()
                state.careItems = Self.sortedCare(state.careItems + [item])
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, item)
                }

            case .dismissCareSuggestions:
                state.careSuggestionsDismissed = true
                return .none

            case .addYardZoneTapped:
                // A new yard zone starts with one yearly seasonal task and zone-flavored option sets
                // (no photo/species — those stay plant-only).
                state.careForm = CareItemFormReducer.State(
                    item: CareItem(
                        kind: .zone, name: "", iconSymbol: "tree.fill",
                        tasks: [CareTask(title: "", intervalDays: 365)]
                    ),
                    isEditing: false
                )
                return .none

            case let .yardSuggestionTapped(suggestion):
                guard let (hid, _) = ctx() else { return .none }
                let item = suggestion.makeItem()
                state.careItems = Self.sortedCare(state.careItems + [item])
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, item)
                }

            case .dismissYardSuggestions:
                state.yardSuggestionsDismissed = true
                return .none

            case .addPetTapped:
                // A new pet pre-fills the standard dog-care schedule and pet-flavored icon/interval
                // sets, plus the shared photo picker and breed/birthday/vet fields (kind == .pet).
                state.careForm = CareItemFormReducer.State(
                    item: CareItem(
                        kind: .pet, name: "", iconSymbol: "pawprint.fill",
                        tasks: PetSuggestion.defaultTasks()
                    ),
                    isEditing: false
                )
                return .none

            case let .petSuggestionTapped(suggestion):
                guard let (hid, _) = ctx() else { return .none }
                let item = suggestion.makeItem()
                state.careItems = Self.sortedCare(state.careItems + [item])
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, item)
                }

            case .dismissPetSuggestions:
                state.petSuggestionsDismissed = true
                return .none

            case .petScheduleSetupOpened:
                // Fire-and-forget telemetry when the pet's "Set up care schedule" section is opened.
                analytics.log("pet_schedule_setup")
                return .none

            case let .materializePetCareTask(petID, templateID, alreadyDone):
                // Append a PetCareKB recommendation onto the pet's OWN CareItem (pets already exist as
                // care items — unlike house maintenance, which mints a fresh item). Backdated when the
                // family already does it, else due today. Persist through the same saveCareItem path.
                guard let (hid, uid) = ctx(),
                      let i = state.careItems.firstIndex(where: { $0.id == petID }),
                      state.careItems[i].kind == .pet,
                      let template = PetCareKB.template(id: templateID)
                else { return .none }
                // Don't duplicate a recommendation the pet already tracks (title-keyword match).
                guard !state.careItems[i].tasks.contains(where: { template.matches($0) }) else { return .none }
                let task = template.makeCareTask(alreadyDone: alreadyDone, by: uid)
                state.careItems[i].tasks.append(task)
                state.careItems = Self.sortedCare(state.careItems)
                let toSave = state.careItems.first { $0.id == petID }
                analytics.log("pet_care_task_added", ["template": templateID])
                return .run { _ in
                    guard let toSave else { return }
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, toSave)
                }

            case .plantScheduleSetupOpened:
                // Fire-and-forget telemetry when the plant's "Recommended schedule" section is opened.
                analytics.log("plant_schedule_setup")
                return .none

            case let .materializePlantCareTask(plantID, templateID, alreadyDone):
                // Append a PlantCareKB recommendation onto the plant's OWN CareItem (plants already exist
                // as care items — unlike house maintenance, which mints a fresh item). Backdated when the
                // family already does it, else due today. Persist through the same saveCareItem path.
                guard let (hid, uid) = ctx(),
                      let i = state.careItems.firstIndex(where: { $0.id == plantID }),
                      state.careItems[i].kind == .plant,
                      let template = PlantCareKB.template(id: templateID, for: state.careItems[i])
                else { return .none }
                // Don't duplicate a recommendation the plant already tracks (title-keyword match).
                guard !state.careItems[i].tasks.contains(where: { template.matches($0) }) else { return .none }
                let plantTask = template.makeCareTask(alreadyDone: alreadyDone, by: uid)
                state.careItems[i].tasks.append(plantTask)
                state.careItems = Self.sortedCare(state.careItems)
                let plantToSave = state.careItems.first { $0.id == plantID }
                analytics.log("plant_care_task_added", ["template": templateID])
                return .run { _ in
                    guard let plantToSave else { return }
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveCareItem(hid, plantToSave)
                }

            case let .recallRitual(ritual):
                // Route the recall to the ritual's OWN bridge (mirrors Today's card); ignore if that
                // bridge isn't paired or another recall is already in flight. Hue scene only — shade
                // actions are a Today-card refinement not wired into the hub preview.
                guard state.recallingRitual == nil,
                      let config = state.houseCard.config,
                      let bridge = config.bridge(ritual.bridgeId) else { return .none }
                analytics.log("ritual_recalled", ["ritual": ritual.key])
                state.recallingRitual = ritual.key
                return .run { send in
                    @Dependency(\.hue) var hue
                    // Best-effort: recall failures degrade silently (the card never shows errors).
                    try? await hue.recallScene(bridge, ritual.groupId, ritual.sceneId)
                    await send(.ritualRecallFinished(key: ritual.key))
                }

            case let .ritualRecallFinished(key):
                if state.recallingRitual == key { state.recallingRitual = nil }
                return .none

            case .careForm(.presented(.delegate(.didChange))):
                return .send(.task)

            case .form(.presented(.delegate(.didChange))):
                return .send(.task)

            case .plantCapture(.presented(.delegate(.didFinish))):
                return .send(.task)

            case .form, .careForm, .plantCapture, .troubleshoot, .houseCard, .homeMaintenance, .binding:
                return .none
            }
        }
        .ifLet(\.$form, action: \.form) {
            ChoreFormReducer()
        }
        .ifLet(\.$careForm, action: \.careForm) {
            CareItemFormReducer()
        }
        .ifLet(\.$homeMaintenance, action: \.homeMaintenance) {
            HomeMaintenanceReducer()
        }
        .ifLet(\.$plantCapture, action: \.plantCapture) {
            PlantCaptureReducer()
        }
        .ifLet(\.$troubleshoot, action: \.troubleshoot) {
            PlantTroubleshootReducer()
        }
    }

    /// Overdue/due-soonest first, then by creation time — mirrors how the row shows the soonest task.
    static func sortedCare(_ items: [CareItem], now: Date = Date()) -> [CareItem] {
        items.sorted {
            let a = $0.soonestDueTask(now: now)?.daysUntilDue(now: now) ?? Int.max
            let b = $1.soonestDueTask(now: now)?.daysUntilDue(now: now) ?? Int.max
            return a == b ? $0.createdAt < $1.createdAt : a < b
        }
    }

    // MARK: XP redemption helper (XP awards themselves are server-side, via onChoreToggled)

    private func apply(_ stats: MemberStats, to all: inout [MemberStats]) {
        if let i = all.firstIndex(where: { $0.memberID == stats.memberID }) { all[i] = stats }
        else { all.append(stats) }
    }
}

private extension String {
    /// `nil` when the string is empty, else `self` — used to fold a blank room string into the same
    /// "no room yet" bucket as a `nil` location.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
