import ComposableArchitecture
import FamilyDomain
import Foundation
import HueClient
import LocationClient
import LutronClient
import MenereUI
import NestClient
import PersistenceClient
import UserDomain

/// The live snapshot behind the Today "house" card (P12-C3, multi-bridge): the config plus one
/// `BridgeSnapshot` per **reachable** bridge. Present only when at least one bridge was reachable;
/// its absence *is* the "no card" state (not home, or never paired). One unreachable bridge among
/// several does not hide the card — its snapshot is simply missing from `bridges`.
public struct HouseSnapshot: Equatable, Sendable {
    public var config: HueConfig
    /// Only the bridges that answered. `bridges.isEmpty` ⇢ no card.
    public var bridges: [BridgeSnapshot]

    public init(config: HueConfig, bridges: [BridgeSnapshot]) {
        self.config = config
        self.bridges = bridges
    }

    /// Rooms merged across every reachable bridge.
    public var rooms: [HueRoom] { bridges.flatMap(\.rooms) }
    /// Lights merged across every reachable bridge.
    public var lights: [HueLight] { bridges.flatMap(\.lights) }
    /// Scenes merged across every reachable bridge.
    public var scenes: [HueScene] { bridges.flatMap(\.scenes) }
    /// Which bridges are reachable right now (gates each ritual button on its own bridge).
    public var reachableBridgeIds: Set<String> { Set(bridges.map(\.bridge.bridgeId)) }

    /// Rituals whose owning bridge is reachable — the only ones that can render / recall.
    public var recallableRituals: [HueRitual] {
        let reachable = reachableBridgeIds
        return config.rituals.filter { reachable.contains($0.bridgeId) }
    }

    /// (label, °F) for every labeled temperature sensor across bridges, scoped per-bridge so a
    /// sensor id that recurs on two bridges never crosses labels. Sorted by label.
    public var labeledTemperatures: [(label: String, tempF: Double)] {
        bridges.flatMap { snap -> [(label: String, tempF: Double)] in
            let labels = config.sensorLabels(for: snap.bridge.bridgeId)
            return snap.temperatures.compactMap { t in
                guard let label = labels[t.sensorId] else { return nil }
                return (label, t.tempF)
            }
        }
        .sorted { $0.label < $1.label }
    }
}

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

        /// Live Hue snapshot behind the "house" card (P12). Loaded by an INDEPENDENT effect: nil
        /// whenever there's no config doc OR the bridge is unreachable (even after a rediscover) —
        /// in both cases the card simply hides. This card NEVER surfaces an error.
        var house: HouseSnapshot?
        /// The household's Lutron shade config (P15-C1), loaded independently alongside the house card.
        /// Passed into `HouseView` (which loads live shade levels on appear) and consulted when a
        /// ritual carries `shadeActions`. Nil = no shades paired.
        var lutronConfig: LutronConfig?
        /// The household's OPTIONAL Sonos config (P15-C2). Unlike Lutron, nil does NOT hide speakers —
        /// Sonos discovers live off the LAN with no pairing; the doc only forces the mock or carries a
        /// cosmetic room order. Passed into `HouseView`, which discovers speakers on appear.
        var sonosConfig: SonosConfig?
        /// The household's Nest config (P15-C3), loaded independently alongside the house card. Passed
        /// into `HouseView`, which loads live thermostat state on appear. Nil = Nest not set up.
        var nestConfig: NestConfig?
        /// The ritual key whose scene recall is in flight (drives the button's pending state).
        var recallingRitual: String?
        /// The ritual key that just succeeded — drives the checkmark morph + success haptic until
        /// `clearRitualSuccess` fires.
        var succeededRitual: String?

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
        /// Load/refresh the Hue "house" card (independent, non-blocking; hides itself on any issue).
        case loadHouse
        case houseLoaded(HouseSnapshot?)
        /// Load the Lutron shade config (independent, non-blocking).
        case loadLutronConfig
        case lutronConfigLoaded(LutronConfig?)
        /// Load the optional Sonos config (independent, non-blocking). Absent → still live-discovers.
        case loadSonosConfig
        case sonosConfigLoaded(SonosConfig?)
        /// Load the Nest config (independent, non-blocking). Absent → the Climate section hides.
        case loadNestConfig
        case nestConfigLoaded(NestConfig?)
        /// Recall a ritual's scene (Bedtime / Dinner's ready).
        case recallRitual(HueRitual)
        case ritualRecallFinished(key: String)
        case clearRitualSuccess(key: String)
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

    private enum CancelID { case briefing, drive, house }

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
                    // The "house" card loads independently too — never blocks/breaks the dashboard.
                    .send(.loadHouse),
                    // Lutron shade config (P15) — for HouseView + ritual shadeActions.
                    .send(.loadLutronConfig),
                    // Sonos config (P15-C2) — optional; HouseView discovers speakers regardless.
                    .send(.loadSonosConfig),
                    // Nest config (P15-C3) — for HouseView's Climate section.
                    .send(.loadNestConfig),
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

            case .loadHouse:
                // No household → no card, zero cost.
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.hue) var hue
                    // No config doc → no card (never paired). `hueConfig` already returns an
                    // Optional; `try?` flattens the throwing wrapper, so one unwrap suffices.
                    guard let config = try? await persistence.hueConfig(hid), !config.bridges.isEmpty else {
                        await send(.houseLoaded(nil)); return
                    }

                    // Fan reads across ALL bridges concurrently, each independently resilient — one
                    // unreachable bridge never hides another's data.
                    var snapshots = await hue.readHouse(config.bridges)

                    // For any bridge that DIDN'T answer, try a single cloud rediscover to heal an IP
                    // drift, re-read, and persist the corrected `bridges` array on success.
                    let reached = Set(snapshots.map(\.bridge.bridgeId))
                    var healedBridges = config.bridges
                    var didHeal = false
                    for bridge in config.bridges where !reached.contains(bridge.bridgeId) {
                        guard let freshIP = try? await hue.rediscover(bridge.bridgeId),
                              freshIP != bridge.bridgeIP else { continue }
                        var healed = bridge
                        healed.bridgeIP = freshIP
                        if let snapshot = try? await hue.readBridge(healed) {
                            snapshots.append(snapshot)
                            if let i = healedBridges.firstIndex(where: { $0.bridgeId == bridge.bridgeId }) {
                                healedBridges[i].bridgeIP = freshIP
                            }
                            didHeal = true
                        }
                    }
                    if didHeal { try? await persistence.updateHueBridges(hid, healedBridges) }

                    // No bridge reachable → "not home = no card".
                    guard !snapshots.isEmpty else { await send(.houseLoaded(nil)); return }
                    snapshots.sort { $0.bridge.bridgeId < $1.bridge.bridgeId }
                    await send(.houseLoaded(HouseSnapshot(config: config, bridges: snapshots)))
                }
                .cancellable(id: CancelID.house, cancelInFlight: true)

            case let .houseLoaded(snapshot):
                state.house = snapshot
                return .none

            case .loadLutronConfig:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let config = try? await persistence.lutronConfig(hid)
                    await send(.lutronConfigLoaded(config ?? nil))
                }

            case let .lutronConfigLoaded(config):
                state.lutronConfig = config
                return .none

            case .loadSonosConfig:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let config = try? await persistence.sonosConfig(hid)
                    await send(.sonosConfigLoaded(config ?? nil))
                }

            case let .sonosConfigLoaded(config):
                state.sonosConfig = config
                return .none

            case .loadNestConfig:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let config = try? await persistence.nestConfig(hid)
                    await send(.nestConfigLoaded(config ?? nil))
                }

            case let .nestConfigLoaded(config):
                state.nestConfig = config
                return .none

            case let .recallRitual(ritual):
                // Route the recall to the ritual's OWN bridge; ignore if that bridge isn't paired.
                guard let bridge = state.house?.config.bridge(ritual.bridgeId),
                      state.recallingRitual == nil else { return .none }
                state.recallingRitual = ritual.key
                // P15-C1: a ritual may ALSO carry shade actions — fire them fire-and-forget alongside
                // the Hue scene (best-effort; the card never surfaces a shade error). Bedtime both dims
                // the boys' lights and closes their shades in one tap.
                let shadeActions = ritual.shadeActions ?? []
                let lutronConfig = state.lutronConfig
                return .run { send in
                    @Dependency(\.hue) var hue
                    @Dependency(\.lutron) var lutron
                    // Best-effort: recall failures degrade silently (the card never shows errors).
                    try? await hue.recallScene(bridge, ritual.groupId, ritual.sceneId)
                    if let lutronConfig, !shadeActions.isEmpty {
                        await withTaskGroup(of: Void.self) { group in
                            for action in shadeActions {
                                group.addTask {
                                    try? await lutron.setShadeLevel(lutronConfig, action.zoneId, action.level)
                                }
                            }
                        }
                    }
                    await send(.ritualRecallFinished(key: ritual.key))
                }

            case let .ritualRecallFinished(key):
                state.recallingRitual = nil
                state.succeededRitual = key
                // Refresh the lights summary, then clear the success state after a brief beat.
                return .merge(
                    .send(.loadHouse),
                    .run { send in
                        try? await Task.sleep(for: .seconds(1.6))
                        await send(.clearRitualSuccess(key: key))
                    }
                )

            case let .clearRitualSuccess(key):
                if state.succeededRitual == key { state.succeededRitual = nil }
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
