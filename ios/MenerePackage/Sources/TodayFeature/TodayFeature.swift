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
        /// The signed-in member's first name (first whitespace token), or nil if unknown.
        var firstName: String?
        var isLoading = false

        public init() {}
    }

    public enum Action: Equatable {
        case task
        case loaded(events: [FamilyEvent], members: [HouseholdMember], recipes: [Recipe], mealPlan: [MealPlanEntry])
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

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
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
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    // All loads resilient: a failed fetch degrades to an empty state.
                    async let events = persistence.events(hid)
                    async let members = persistence.members(hid)
                    async let recipes = persistence.recipes(hid)
                    async let plan = persistence.mealPlan(hid)
                    await send(.loaded(
                        events: (try? await events) ?? [],
                        members: (try? await members) ?? [],
                        recipes: (try? await recipes) ?? [],
                        mealPlan: (try? await plan) ?? []
                    ))
                }

            case let .loaded(events, members, recipes, mealPlan):
                state.isLoading = false
                state.events = events
                state.members = members
                state.recipes = recipes
                state.mealPlan = mealPlan
                state.firstName = firstName(from: members)
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
