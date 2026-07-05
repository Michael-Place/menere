import AnalyticsClient
import CalendarFeature
import ComposableArchitecture
import DocsFeature
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

/// Identifies the member whose "day" sheet is presented (P17-C1). An `Identifiable` wrapper so the
/// view can drive a `.sheet(item:)` off a plain member id.
public struct MemberDaySelection: Identifiable, Equatable, Sendable {
    public let id: String
    public init(id: String) { self.id = id }
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
        /// The household's Hubspace config (P15-C4), loaded independently alongside the house card.
        /// Passed into `HouseView`, which loads live spigot state on appear. Nil = Hubspace not set up.
        var hubspaceConfig: HubspaceConfig?
        /// The household's Meross/Refoss garage config (P15-C5), loaded independently alongside the house
        /// card. Passed into `HouseView`, which loads live door state on appear. Nil = garage not set up.
        var merossConfig: MerossConfig?
        /// The household's OPTIONAL HomeKit config (P15-C7) — nil is fine (HomeKit reads the live local
        /// Home once authorized; the doc only forces the mock). Passed into `HouseView`.
        var homekitConfig: HomeKitConfig?
        /// The ritual key whose scene recall is in flight (drives the button's pending state).
        var recallingRitual: String?
        /// The ritual key that just succeeded — drives the checkmark morph + success haptic until
        /// `clearRitualSuccess` fires.
        var succeededRitual: String?

        /// The Family-Brain document pushed from a tapped Family Radar row (P20). Reuses the full
        /// `DocumentDetailReducer` (pages, fields, its own idempotent add-to-calendar).
        @Presents var docDetail: DocumentDetailReducer.State?

        /// P17-C1 — tapping a schedule row opens the tapped event for edit in the SAME
        /// `EventFormReducer` the Calendar tab uses (reschedule / edit / delete, one save path).
        @Presents var eventForm: EventFormReducer.State?
        /// P17-C1 — the member whose lightweight "day" sheet is open (their events + chores + care
        /// today). Read-only, computed in the view from already-loaded state. nil = closed.
        var memberDay: MemberDaySelection?
        /// P17-C1 — drives the "Change dinner" recipe picker sheet (assigns tonight's meal-plan entry
        /// through the same persistence path the Kitchen tab uses).
        var showDinnerPicker = false

        /// P28-C1 — the day the week strip has selected. The schedule card scopes to it; the day-of is
        /// the default. `selectDay` moves it; today stays time-aware (past collapses), other days show a
        /// plain agenda.
        var selectedDay: Date = Calendar.current.startOfDay(for: Date())

        public init() {}

        /// The household's pets (care items of kind `.pet`) — the Family Radar names pet-linked docs
        /// ("Sprinkle's rabies") from these.
        var pets: [CareItem] { careItems.filter { $0.kind == .pet } }

        /// The Family Radar over every document + pet — the pure model behind the card and the detail
        /// list. Recomputed on demand (cheap at family scale) so it always reflects the latest docs.
        func radar(now: Date = Date()) -> FamilyRadar {
            FamilyRadar.compute(documents: documents, pets: pets, now: now)
        }

        /// Whether an all-day event with this doc's title already sits on its `dueDate` day — drives
        /// the radar row's idempotent "Add to calendar" done-state (mirrors `DocumentDetailReducer`).
        func radarOnCalendar(_ item: FamilyRadar.Item) -> Bool {
            guard let due = item.doc.dueDate else { return false }
            let cal = Calendar.current
            return events.contains { $0.title == item.doc.title && cal.isDate($0.startDate, inSameDayAs: due) }
        }

        /// Whether a "Renew …" reminder for an expired vaccine has already been dropped on the calendar.
        func radarRenewScheduled(_ item: FamilyRadar.Item) -> Bool {
            events.contains { $0.title == item.renewTitle }
        }

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
        /// Load the Hubspace config (independent, non-blocking). Absent → the Water section hides.
        case loadHubspaceConfig
        case hubspaceConfigLoaded(HubspaceConfig?)
        /// Load the Meross/Refoss garage config (independent, non-blocking). Absent → the Garage section hides.
        case loadMerossConfig
        case merossConfigLoaded(MerossConfig?)
        /// Load the OPTIONAL HomeKit config (independent, non-blocking). Absent → HomeKit still reads live.
        case loadHomeKitConfig
        case homekitConfigLoaded(HomeKitConfig?)
        /// Recall a ritual's scene (Bedtime / Dinner's ready).
        case recallRitual(HueRitual)
        case ritualRecallFinished(key: String)
        case clearRitualSuccess(key: String)
        /// Drop tonight's reservation on the shared calendar as a "Dinner at {name}" event.
        case addDinnerToCalendarTapped
        case dinnerEventAdded(FamilyEvent)
        // Quick-action deep links — the parent (MainTabReducer) switches tabs in response.
        /// "+ Add event" (P28) — presents a NEW event in the SAME `EventFormReducer` the Calendar
        /// drill-in uses (seeded on the week strip's selected day).
        case quickAddEventTapped
        case quickAddListTapped
        case planDinnerTapped
        /// P28-C1 — "Open full calendar" pushes the full `CalendarFeature` (month grid + agenda +
        /// recurrence + Apple sync). The parent (MainTabReducer) drives the push.
        case openFullCalendarTapped
        /// P28-C1 — a week-strip day was tapped; the schedule card re-scopes to it.
        case selectDay(Date)
        // Family Radar (P20).
        /// The Radar detail list appeared — telemetry (`family_radar_opened`).
        case radarOpened
        /// A radar row was tapped — logs `radar_item_tapped` and pushes the linked document detail.
        case radarItemTapped(docID: String)
        /// One-tap idempotent "Add to calendar" from a radar item's due date.
        case radarAddToCalendarTapped(docID: String)
        /// One-tap "Add a reminder to renew" for an expired vaccine — an all-day nudge ~today+3d.
        case radarRenewReminderTapped(docID: String)
        /// A radar-driven event was written — reflected locally so the row swaps to its done state.
        case radarEventAdded(FamilyEvent)
        /// P20-C2 — snooze a radar item off the loud card (~90 days). Persists `radarDismissedUntil`.
        case radarItemDismissed(docID: String)
        case docDetail(PresentationAction<DocumentDetailReducer.Action>)
        // P17-C1 — actionable Today.
        /// A schedule row was tapped → open that event for edit (logs `today_event_tapped`).
        case eventTapped(FamilyEvent)
        case eventForm(PresentationAction<EventFormReducer.Action>)
        /// Reload just the events list after an edit/delete round-trips through the form.
        case reloadEvents
        case eventsReloaded([FamilyEvent])
        /// A family member card was tapped → open their day sheet (logs `today_member_tapped`).
        case memberTapped(String)
        case memberDayDismissed
        /// "Change dinner" tapped → open the recipe picker.
        case changeDinnerTapped
        case dinnerPickerDismissed
        /// Assign a recipe as tonight's dinner from the picker (logs `today_dinner_changed`); reuses
        /// the meal-plan persistence path.
        case assignDinner(Recipe)
        case delegate(Delegate)
    }

    /// Navigation intents surfaced to `MainTabReducer`. Feature-agnostic (no AppCore import) so the
    /// parent owns the mapping. `openCalendar` now pushes the full calendar as a drill-in (P28);
    /// `openLists`/`openKitchen` still switch tabs.
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
        let full = (user?.id).flatMap { members.member(forUID: $0) }?.name ?? user?.displayName
        guard let token = full?.split(whereSeparator: { $0.isWhitespace }).first, !token.isEmpty else {
            return nil
        }
        return String(token)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                @Dependency(\.analytics) var analytics
                analytics.log("today_opened")   // P25 telemetry (fire-and-forget)
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
                    // Hubspace config (P15-C4) — for HouseView's Water section.
                    .send(.loadHubspaceConfig),
                    // Meross/Refoss garage config (P15-C5) — for HouseView's Garage section.
                    .send(.loadMerossConfig),
                    // HomeKit config (P15-C7) — OPTIONAL; only forces the mock. HouseView reads live HomeKit.
                    .send(.loadHomeKitConfig),
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

            case .loadHubspaceConfig:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let config = try? await persistence.hubspaceConfig(hid)
                    await send(.hubspaceConfigLoaded(config ?? nil))
                }

            case let .hubspaceConfigLoaded(config):
                state.hubspaceConfig = config
                return .none

            case .loadMerossConfig:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let config = try? await persistence.merossConfig(hid)
                    await send(.merossConfigLoaded(config ?? nil))
                }

            case let .merossConfigLoaded(config):
                state.merossConfig = config
                return .none

            case .loadHomeKitConfig:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let config = try? await persistence.homekitConfig(hid)
                    await send(.homekitConfigLoaded(config ?? nil))
                }

            case let .homekitConfigLoaded(config):
                state.homekitConfig = config
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
                // P28: present a NEW event in the Calendar's own form, seeded on the selected day at a
                // sensible hour — the same save path (and Apple push, on the next sync) as the Calendar.
                @Dependency(\.date.now) var now
                @Dependency(\.analytics) var analytics
                analytics.log("today_add_event")
                let cal = Calendar.current
                let hour = (cal.component(.hour, from: now) + 1)
                let start = cal.date(bySettingHour: min(hour, 22), minute: 0, second: 0, of: state.selectedDay)
                    ?? state.selectedDay
                state.eventForm = EventFormReducer.State(
                    event: FamilyEvent(title: "", startDate: start, endDate: start.addingTimeInterval(3600)),
                    isEditing: false,
                    members: state.members
                )
                return .none

            case .openFullCalendarTapped:
                @Dependency(\.analytics) var analytics
                analytics.log("today_open_full_calendar")
                return .send(.delegate(.openCalendar))

            case let .selectDay(day):
                state.selectedDay = Calendar.current.startOfDay(for: day)
                return .none

            case .quickAddListTapped:
                return .send(.delegate(.openLists))

            case .planDinnerTapped:
                return .send(.delegate(.openKitchen))

            case .radarOpened:
                @Dependency(\.analytics) var analytics
                analytics.log("family_radar_opened")
                return .none

            case let .radarItemTapped(docID):
                guard let doc = state.documents.first(where: { $0.id == docID }) else { return .none }
                @Dependency(\.analytics) var analytics
                analytics.log("radar_item_tapped", [
                    "type": doc.type.rawValue,
                    "radar_kind": FamilyRadar.classify(doc).rawValue,
                ])
                state.docDetail = DocumentDetailReducer.State(doc: doc)
                return .none

            case let .radarAddToCalendarTapped(docID):
                // Idempotent: mirror DocumentDetailReducer — one all-day event on the due day.
                guard let hid = hid(),
                      let doc = state.documents.first(where: { $0.id == docID }),
                      let due = doc.dueDate else { return .none }
                let item = FamilyRadar.Item(doc: doc, date: due, kind: .due, days: 0, petName: nil)
                guard !state.radarOnCalendar(item) else { return .none }
                let event = FamilyEvent(
                    title: doc.title, startDate: due, isAllDay: true, notes: "From Family Brain"
                )
                @Shared(.user) var user
                let actorID = user?.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveEvent(hid, event)
                    try? await persistence.logActivity(hid, .eventAdded(title: event.title, actorID: actorID))
                    await send(.radarEventAdded(event))
                }

            case let .radarRenewReminderTapped(docID):
                // A gentle nudge ~3 days out to renew an expired vaccine — idempotent by title.
                guard let hid = hid(),
                      let doc = state.documents.first(where: { $0.id == docID }) else { return .none }
                let petName = state.pets.first { doc.linkedPetIds.contains($0.id) }?.name
                let radarItem = FamilyRadar.Item(
                    doc: doc, date: doc.expiryDate ?? Date(), kind: .expiry, days: -1, petName: petName
                )
                guard !state.radarRenewScheduled(radarItem) else { return .none }
                let cal = Calendar.current
                let when = cal.date(byAdding: .day, value: 3, to: cal.startOfDay(for: Date())) ?? Date()
                let event = FamilyEvent(
                    title: radarItem.renewTitle, startDate: when, isAllDay: true,
                    notes: "Family Radar reminder"
                )
                @Shared(.user) var user
                let actorID = user?.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveEvent(hid, event)
                    try? await persistence.logActivity(hid, .eventAdded(title: event.title, actorID: actorID))
                    await send(.radarEventAdded(event))
                }

            case let .radarEventAdded(event):
                state.events.append(event)
                return .none

            case let .radarItemDismissed(docID):
                // Snooze this item off the loud card for ~90 days (or until its date changes). Persisted
                // on the doc so it survives relaunch; reversible by clearing `radarDismissedUntil`.
                guard let hid = hid(),
                      let i = state.documents.firstIndex(where: { $0.id == docID }) else { return .none }
                let cal = Calendar.current
                let until = cal.date(byAdding: .day, value: 90, to: cal.startOfDay(for: Date())) ?? Date()
                state.documents[i].radarDismissedUntil = until
                let doc = state.documents[i]
                @Dependency(\.analytics) var analytics
                analytics.log("radar_item_dismissed", ["radar_kind": FamilyRadar.classify(doc).rawValue])
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveDocument(hid, doc)
                }

            case let .docDetail(.presented(.delegate(.didChange(doc)))):
                // Keep the radar fresh when the pushed detail edits a doc (rename / retype / link pet).
                if let i = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[i] = doc
                }
                return .none

            case let .docDetail(.presented(.delegate(.didDelete(id)))):
                state.documents.removeAll { $0.id == id }
                return .none

            case .docDetail:
                return .none

            case let .eventTapped(event):
                @Dependency(\.analytics) var analytics
                analytics.log("today_event_tapped")
                // Seed the SAME form the Calendar tab uses — reschedule / edit / delete round-trip
                // through its existing save path (no new persistence).
                state.eventForm = EventFormReducer.State(event: event, isEditing: true, members: state.members)
                return .none

            case .eventForm(.presented(.delegate(.didChange))):
                // The form saved or deleted the event — refresh the schedule so Today reflects it.
                return .send(.reloadEvents)

            case .eventForm:
                return .none

            case .reloadEvents:
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let events = (try? await persistence.events(hid)) ?? []
                    await send(.eventsReloaded(events))
                }

            case let .eventsReloaded(events):
                state.events = events
                return .none

            case let .memberTapped(id):
                @Dependency(\.analytics) var analytics
                analytics.log("today_member_tapped")
                state.memberDay = MemberDaySelection(id: id)
                return .none

            case .memberDayDismissed:
                state.memberDay = nil
                return .none

            case .changeDinnerTapped:
                state.showDinnerPicker = true
                return .none

            case .dinnerPickerDismissed:
                state.showDinnerPicker = false
                return .none

            case let .assignDinner(recipe):
                state.showDinnerPicker = false
                guard let hid = hid() else { return .none }
                @Dependency(\.analytics) var analytics
                analytics.log("today_dinner_changed")
                @Dependency(\.date.now) var now
                let day = Calendar.current.startOfDay(for: now)
                // Replace any existing entry for today — same shape as RecipesReducer.assignMeal.
                let existing = state.mealPlan.first { Calendar.current.isDate($0.date, inSameDayAs: day) }
                let entry = MealPlanEntry(
                    id: existing?.id ?? UUID().uuidString,
                    date: day, recipeID: recipe.id, recipeTitle: recipe.title
                )
                if let i = state.mealPlan.firstIndex(where: { $0.id == entry.id }) {
                    state.mealPlan[i] = entry
                } else {
                    state.mealPlan.append(entry)
                }
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveMealPlanEntry(hid, entry)
                }

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$docDetail, action: \.docDetail) {
            DocumentDetailReducer()
        }
        .ifLet(\.$eventForm, action: \.eventForm) {
            EventFormReducer()
        }
    }
}
