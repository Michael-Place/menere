import ComposableArchitecture
import FamilyDomain
import Foundation
import LocationClient
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
        /// Family-Brain documents — powers the "Needs attention" card (due/expiring soon).
        var documents: [FamilyDomain.Document] = []
        /// House-care items — powers the "Home care" card (due/overdue care tasks).
        var careItems: [CareItem] = []
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

        /// Traffic-aware drive time (minutes) to tonight's restaurant. Loaded by an INDEPENDENT
        /// effect after the cards render; nil (hidden) until it resolves and on any failure — the
        /// dashboard never waits on MapKit.
        var driveMinutes: Int?

        public init() {}

        func stats(for memberID: String) -> MemberStats {
            stats.first { $0.memberID == memberID } ?? MemberStats(id: memberID, memberID: memberID)
        }

        /// Tonight's meal-plan entry (today's date), if any.
        func tonightsEntry() -> MealPlanEntry? {
            let cal = Calendar.current
            return mealPlan.first { cal.isDateInToday($0.date) }
        }

        /// Whether the "Dinner at {name}" event already sits on the reservation day — drives the
        /// add-to-calendar button's idempotent done state.
        var dinnerOnCalendar: Bool {
            guard let entry = tonightsEntry(), entry.isEatingOut, let reservationAt = entry.reservationAt
            else { return false }
            let title = "Dinner at \(entry.restaurantName ?? "")"
            let cal = Calendar.current
            return events.contains {
                $0.title == title && cal.isDate($0.startDate, inSameDayAs: reservationAt)
            }
        }
    }

    public enum Action: Equatable {
        case task
        case loaded(
            events: [FamilyEvent], members: [HouseholdMember], recipes: [Recipe],
            mealPlan: [MealPlanEntry], chores: [Chore], stats: [MemberStats],
            documents: [FamilyDomain.Document], careItems: [CareItem]
        )
        /// Complete/uncomplete a chore from the Today "Chores today" card. Behaves identically to
        /// completing it in the Chores tab (shared ``ChoreCompletion`` logic).
        case toggleChore(Chore)
        /// Mark a care task done from the Today "Home care" card. Behaves identically to the Home
        /// tab (shared ``CareCompletion`` logic + best-effort activity log).
        case markCareTaskDone(itemID: String, taskID: String)
        /// Load/refresh the AI briefing. `force` bypasses the per-day server cache (refresh button).
        case loadBriefing(force: Bool)
        case briefingResponse(DailyBriefing?)
        /// Kick the traffic-aware ETA to tonight's restaurant (independent, non-blocking).
        case computeDrive
        case driveResult(Int?)
        /// Drop tonight's reservation on the shared calendar as a "Dinner at {name}" event.
        case addDinnerToCalendarTapped
        case dinnerEventAdded(FamilyEvent)
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

    private enum CancelID { case briefing, drive }

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
                        async let documents = persistence.documents(hid)
                        async let careItems = persistence.careItems(hid)
                        await send(.loaded(
                            events: (try? await events) ?? [],
                            members: (try? await members) ?? [],
                            recipes: (try? await recipes) ?? [],
                            mealPlan: (try? await plan) ?? [],
                            chores: (try? await chores) ?? [],
                            stats: (try? await stats) ?? [],
                            documents: (try? await documents) ?? [],
                            careItems: (try? await careItems) ?? []
                        ))
                    },
                    .send(.loadBriefing(force: false)),
                    // Ask once so tonight's drive time can resolve (idempotent; no-op if determined).
                    .run { _ in
                        @Dependency(\.location) var location
                        location.requestWhenInUseAuthorization()
                    }
                )

            case let .loaded(events, members, recipes, mealPlan, chores, stats, documents, careItems):
                state.isLoading = false
                state.events = events
                state.members = members
                state.recipes = recipes
                state.mealPlan = mealPlan
                state.chores = chores
                state.stats = stats
                state.documents = documents
                state.careItems = careItems
                state.firstName = firstName(from: members)
                // Once cards have data, fire the drive-time lookup independently (never blocks).
                if let entry = state.tonightsEntry(), entry.hasPlace {
                    return .send(.computeDrive)
                }
                state.driveMinutes = nil
                return .none

            case .computeDrive:
                guard let entry = state.tonightsEntry(), entry.hasPlace,
                      let lat = entry.restaurantLatitude, let lng = entry.restaurantLongitude
                else { return .none }
                return .run { send in
                    @Dependency(\.location) var location
                    // Traffic-aware ETA leaving now; nil on any failure → the line stays hidden.
                    let mins = await location.driveTimeMinutes(lat, lng, Date())
                    await send(.driveResult(mins))
                }
                .cancellable(id: CancelID.drive, cancelInFlight: true)

            case let .driveResult(mins):
                state.driveMinutes = mins
                return .none

            case .addDinnerToCalendarTapped:
                guard let hid = hid(), let entry = state.tonightsEntry(), entry.isEatingOut,
                      let reservationAt = entry.reservationAt, !state.dinnerOnCalendar
                else { return .none }
                let name = entry.restaurantName ?? ""
                let event = FamilyEvent(
                    title: "Dinner at \(name)",
                    startDate: reservationAt,
                    isAllDay: false,
                    location: entry.restaurantAddress,
                    notes: "From the meal plan"
                )
                @Shared(.user) var user
                let actorID = user?.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveEvent(hid, event)
                    try? await persistence.logActivity(hid, .eventAdded(title: event.title, actorID: actorID))
                    await send(.dinnerEventAdded(event))
                }

            case let .dinnerEventAdded(event):
                // Reflect locally so the button swaps to "On the calendar" immediately.
                state.events.append(event)
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

            case let .markCareTaskDone(itemID, taskID):
                guard let (hid, uid) = ctx(),
                      let i = state.careItems.firstIndex(where: { $0.id == itemID }),
                      let outcome = CareCompletion.markDone(
                          item: state.careItems[i], taskID: taskID, byMemberID: uid, members: state.members
                      )
                else { return .none }
                // Same shared care-completion path as the Home tab (stamps who-did-it-last + a
                // best-effort activity entry). Marking done recomputes the task's due date, so the
                // row drops off this card immediately.
                state.careItems[i] = outcome.updated
                return .run { [outcome] _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.writeCareDone(hid: hid, outcome)
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
