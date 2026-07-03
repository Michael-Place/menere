import ComposableArchitecture
import FamilyDomain
import HouseFeature
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
        var isLoading = false
        @Presents var form: ChoreFormReducer.State?
        @Presents var careForm: CareItemFormReducer.State?
        /// P9.1 — the Planta-inspired add-a-plant capture wizard. ADD routes here; EDIT stays on
        /// ``careForm``.
        @Presents var plantCapture: PlantCaptureReducer.State?
        // Simple add-reward entry
        var showAddReward = false
        var newRewardTitle = ""
        var newRewardCost = 50
        // Confetti celebration: bumped when the live leaderboard reports a member's level rising;
        // `confettiColor` is that member's color (drives ``ConfettiBurst`` in ``ChoresView``).
        var confettiTrigger = 0
        var confettiColor: MemberColor?

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
        case editCareItemTapped(CareItem)
        case markCareTaskDone(itemID: String, taskID: String)
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
        case carePhotosLoaded([String: Data])
        case form(PresentationAction<ChoreFormReducer.Action>)
        case careForm(PresentationAction<CareItemFormReducer.Action>)
        case plantCapture(PresentationAction<PlantCaptureReducer.Action>)
        case houseCard(HouseCardReducer.Action)
        case binding(BindingAction<State>)
    }

    private enum CancelID { case observeStats }

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
                // Fetch plant photos (kind-agnostic: any care item with a photoPath) into the cache.
                let photoPaths = careItems.compactMap(\.photoPath).filter { !$0.isEmpty }
                guard !photoPaths.isEmpty else { return .none }
                return .run { send in
                    @Dependency(\.storage) var storage
                    var loaded: [String: Data] = [:]
                    for path in photoPaths where loaded[path] == nil {
                        if let data = try? await storage.downloadData(path) { loaded[path] = data }
                    }
                    await send(.carePhotosLoaded(loaded))
                }

            case let .carePhotosLoaded(map):
                state.carePhotos.merge(map) { _, new in new }
                return .none

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

            case .addPlantTapped:
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
                      let outcome = CareCompletion.markDone(
                          item: state.careItems[i], taskID: taskID, byMemberID: uid, members: state.members
                      )
                else { return .none }
                // Shared care-completion logic (see ``CareCompletion``) so Today and Home behave
                // identically: stamp who-did-it-last + a best-effort "took care of…" activity entry.
                state.careItems[i] = outcome.updated
                if let activity = outcome.activity { state.activity.insert(activity, at: 0) }
                return .run { [outcome] _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.writeCareDone(hid: hid, outcome)
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

            case .careForm(.presented(.delegate(.didChange))):
                return .send(.task)

            case .form(.presented(.delegate(.didChange))):
                return .send(.task)

            case .plantCapture(.presented(.delegate(.didFinish))):
                return .send(.task)

            case .form, .careForm, .plantCapture, .houseCard, .binding:
                return .none
            }
        }
        .ifLet(\.$form, action: \.form) {
            ChoreFormReducer()
        }
        .ifLet(\.$careForm, action: \.careForm) {
            CareItemFormReducer()
        }
        .ifLet(\.$plantCapture, action: \.plantCapture) {
            PlantCaptureReducer()
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
