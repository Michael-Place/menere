import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
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
        var isLoading = false
        @Presents var form: ChoreFormReducer.State?
        // Simple add-reward entry
        var showAddReward = false
        var newRewardTitle = ""
        var newRewardCost = 50
        // Confetti celebration: bumped when the live leaderboard reports a member's level rising;
        // `confettiColor` is that member's color (drives ``ConfettiBurst`` in ``ChoresView``).
        var confettiTrigger = 0
        var confettiColor: MemberColor?

        public init() {}

        func stats(for memberID: String) -> MemberStats {
            stats.first { $0.memberID == memberID } ?? MemberStats(id: memberID, memberID: memberID)
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded(chores: [Chore], members: [HouseholdMember], stats: [MemberStats], rewards: [Reward], activity: [ActivityItem])
        case statsUpdated([MemberStats])
        case addTapped
        case editTapped(Chore)
        case toggleComplete(Chore)
        case addRewardTapped
        case createReward
        case redeem(Reward, byMemberID: String)
        case form(PresentationAction<ChoreFormReducer.Action>)
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
        Reduce { state, action in
            switch action {
            case .task:
                guard let (hid, _) = ctx() else { return .none }
                state.isLoading = true
                return .merge(
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        async let chores = persistence.chores(hid)
                        async let members = persistence.members(hid)
                        async let stats = persistence.memberStats(hid)
                        async let rewards = persistence.rewards(hid)
                        async let activity = persistence.activity(hid)
                        await send(.loaded(
                            chores: (try? await chores) ?? [],
                            members: (try? await members) ?? [],
                            stats: (try? await stats) ?? [],
                            rewards: (try? await rewards) ?? [],
                            activity: (try? await activity) ?? []
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

            case let .loaded(chores, members, stats, rewards, activity):
                state.isLoading = false
                state.chores = chores.sorted {
                    $0.isCompleted == $1.isCompleted ? $0.createdAt < $1.createdAt : (!$0.isCompleted && $1.isCompleted)
                }
                state.members = members
                state.stats = stats
                state.rewards = rewards.sorted { $0.xpCost < $1.xpCost }
                state.activity = activity
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

            case .form(.presented(.delegate(.didChange))):
                return .send(.task)

            case .form, .binding:
                return .none
            }
        }
        .ifLet(\.$form, action: \.form) {
            ChoreFormReducer()
        }
    }

    // MARK: XP redemption helper (XP awards themselves are server-side, via onChoreToggled)

    private func apply(_ stats: MemberStats, to all: inout [MemberStats]) {
        if let i = all.firstIndex(where: { $0.memberID == stats.memberID }) { all[i] = stats }
        else { all.append(stats) }
    }
}
