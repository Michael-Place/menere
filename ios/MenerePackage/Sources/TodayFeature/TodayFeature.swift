import ComposableArchitecture
import FamilyDomain
import Foundation
import MenereUI
import PersistenceClient
import UserDomain

/// A single materialized event occurrence on today (recurring events yield many).
/// Mirrors `CalendarFeature.EventOccurrence` — Today reuses the same client-side expansion.
public struct TodayOccurrence: Identifiable, Equatable {
    public let event: FamilyEvent
    public let date: Date
    public var id: String { "\(event.id)@\(date.timeIntervalSince1970)" }
}

/// The "Today" dashboard — the family's front door. P6-C1 ships the scaffold: a time-of-day
/// greeting, today's schedule, tonight's dinner, and a quick-actions row. Later chunks slot in
/// family/chores cards (C2) and an AI briefing card (C3) — see the seams in `TodayView`.
///
/// Pure aggregation over the same one-shot `PersistenceClient` fetches the other features use;
/// no new backend, no observers.
@Reducer
public struct TodayReducer {
    @ObservableState
    public struct State: Equatable {
        var events: [FamilyEvent] = []
        var members: [HouseholdMember] = []
        var recipes: [Recipe] = []
        var mealPlan: [MealPlanEntry] = []
        var chores: [Chore] = []
        /// One-shot leaderboard stats (the live stream stays Chores-tab machinery).
        var stats: [MemberStats] = []
        /// The signed-in member's first name (first whitespace token), or nil if unknown.
        var firstName: String?
        var isLoading = false

        /// AI daily briefing. Loaded by an INDEPENDENT effect so it never blocks the other cards;
        /// on any failure it stays nil and the card hides itself (the dashboard must never look
        /// broken because an AI call failed). `briefingLoading` drives the shimmer skeleton.
        var briefing: DailyBriefing?
        var briefingLoading = false

        public init() {}

        func stats(for memberID: String) -> MemberStats {
            stats.first { $0.memberID == memberID } ?? MemberStats(id: memberID, memberID: memberID)
        }
    }

    public enum Action: Equatable {
        case task
        case loaded(
            events: [FamilyEvent], members: [HouseholdMember], recipes: [Recipe],
            mealPlan: [MealPlanEntry], chores: [Chore], stats: [MemberStats]
        )
        /// Complete/uncomplete a chore from the Today "Chores today" card. Behaves identically to
        /// completing it in the Chores tab (shared ``ChoreCompletion`` logic).
        case toggleChore(Chore)
        /// Load/refresh the AI briefing. `force` bypasses the per-day server cache (refresh button).
        case loadBriefing(force: Bool)
        case briefingResponse(DailyBriefing?)
        // Quick-action deep links — the parent (MainTabReducer) switches tabs in response.
        case quickAddEventTapped
        case quickAddListTapped
        case planDinnerTapped
        case delegate(Delegate)
    }

    /// Tab deep-links surfaced to `MainTabReducer`. Feature-agnostic (no AppCore import) so the
    /// parent owns the tab mapping.
    public enum Delegate: Equatable {
        case openCalendar
        case openLists
        case openKitchen
    }

    public init() {}

    private enum CancelID { case briefing }

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    private func ctx() -> (hid: String, uid: String)? {
        @Shared(.user) var user
        guard let hid = user?.householdId, let uid = user?.id else { return nil }
        return (hid, uid)
    }

    /// First whitespace token of the signed-in member's profile name (falls back to the cached
    /// user's display name), or nil when there's nothing usable.
    private func firstName(from members: [HouseholdMember]) -> String? {
        @Shared(.user) var user
        let full = members.first { $0.id == user?.id }?.name ?? user?.displayName
        guard let token = full?.split(whereSeparator: { $0.isWhitespace }).first, !token.isEmpty else {
            return nil
        }
        return String(token)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else {
                    // No household yet — leave every card in its empty state, never block.
                    state.firstName = firstName(from: [])
                    return .none
                }
                state.isLoading = true
                // The card loads run as ONE effect; the briefing is a SEPARATE, merged effect so a
                // slow/failed AI call never delays the schedule/chores/family cards.
                return .merge(
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        // All loads resilient: a failed fetch degrades to an empty state.
                        async let events = persistence.events(hid)
                        async let members = persistence.members(hid)
                        async let recipes = persistence.recipes(hid)
                        async let plan = persistence.mealPlan(hid)
                        async let chores = persistence.chores(hid)
                        async let stats = persistence.memberStats(hid)
                        await send(.loaded(
                            events: (try? await events) ?? [],
                            members: (try? await members) ?? [],
                            recipes: (try? await recipes) ?? [],
                            mealPlan: (try? await plan) ?? [],
                            chores: (try? await chores) ?? [],
                            stats: (try? await stats) ?? []
                        ))
                    },
                    .send(.loadBriefing(force: false))
                )

            case let .loaded(events, members, recipes, mealPlan, chores, stats):
                state.isLoading = false
                state.events = events
                state.members = members
                state.recipes = recipes
                state.mealPlan = mealPlan
                state.chores = chores
                state.stats = stats
                state.firstName = firstName(from: members)
                return .none

            case let .toggleChore(chore):
                guard let (hid, uid) = ctx(),
                      let idx = state.chores.firstIndex(where: { $0.id == chore.id }) else { return .none }
                // Same shared completion path as the Chores tab (server awards/reverses XP).
                let outcome = chore.isCompleted
                    ? ChoreCompletion.uncomplete(chore)
                    : ChoreCompletion.complete(chore, fallbackCreditID: uid, members: state.members)
                state.chores[idx] = outcome.updated
                if let next = outcome.next { state.chores.append(next) }        // recurring respawn
                return .run { [outcome] _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.writeCompletion(hid: hid, outcome)
                }

            case let .loadBriefing(force):
                // Only meaningful with a household; otherwise leave the card hidden.
                guard hid() != nil else { return .none }
                state.briefingLoading = true
                return .run { send in
                    @Dependency(\.briefing) var briefing
                    // Failure → nil → the card hides (never surfaces an error on the dashboard).
                    let result = try? await briefing.generate(force)
                    await send(.briefingResponse(result))
                }
                .cancellable(id: CancelID.briefing, cancelInFlight: true)

            case let .briefingResponse(result):
                state.briefingLoading = false
                // Keep the last good briefing if a refresh failed, so the card doesn't vanish.
                if let result { state.briefing = result }
                return .none

            case .quickAddEventTapped:
                return .send(.delegate(.openCalendar))

            case .quickAddListTapped:
                return .send(.delegate(.openLists))

            case .planDinnerTapped:
                return .send(.delegate(.openKitchen))

            case .delegate:
                return .none
            }
        }
    }
}
