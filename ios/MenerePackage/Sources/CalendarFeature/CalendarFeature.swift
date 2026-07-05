import CalendarSyncClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// A single materialized occurrence of an event on a given day (recurring events yield many).
public struct EventOccurrence: Identifiable, Equatable {
    public let event: FamilyEvent
    public let date: Date
    public var id: String { "\(event.id)@\(date.timeIntervalSince1970)" }
}

@Reducer
public struct CalendarReducer {
    @ObservableState
    public struct State: Equatable {
        var events: [FamilyEvent] = []
        var members: [HouseholdMember] = []
        var visibleMonth: Date = Calendar.current.startOfDay(for: Date())
        var selectedDate: Date = Calendar.current.startOfDay(for: Date())
        var isLoading = false
        @Presents var form: EventFormReducer.State?

        // MARK: EventKit two-way sync (P2.1)
        var prefs: CalendarSyncPrefs = CalendarSyncPrefs()
        var accessStatus: CalendarAuthStatus = .notDetermined
        var isSyncing = false
        /// Kept for the settings-sheet footer; sync degrades silently everywhere else.
        var lastSyncError: String?
        @Presents var syncSettings: CalendarSyncSettingsReducer.State?

        public init() {}

        var calendarAccessGranted: Bool { accessStatus == .granted }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case eventsLoaded([FamilyEvent])
        case membersLoaded([HouseholdMember])
        case prefsLoaded(CalendarSyncPrefs?)
        case authStatusLoaded(CalendarAuthStatus)
        case shiftMonth(Int)
        case selectDate(Date)
        case addTapped
        case editTapped(FamilyEvent)
        case form(PresentationAction<EventFormReducer.Action>)
        // Sync
        case syncSettingsTapped
        case syncSettings(PresentationAction<CalendarSyncSettingsReducer.Action>)
        case syncNow
        case syncFinished(prefs: CalendarSyncPrefs?, events: [FamilyEvent]?, error: String?)
        case binding(BindingAction<State>)

        // SEAM (P14): agent tools — sync_calendar, query works over imported events automatically
        // (imported Apple events are ordinary FamilyEvents in `households/{hid}/events`, so the P14
        // query_calendar / add_event tools see them with no extra plumbing; a `sync_calendar` tool maps
        // straight onto `.syncNow`).
    }

    public init() {}

    @Dependency(\.persistence) var persistence
    @Dependency(\.calendarSyncClient) var calendarSyncClient

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
                guard let hid = hid() else { return .none }
                state.isLoading = true
                let uid = uid()
                let status = calendarSyncClient.authorizationStatus()
                state.accessStatus = status
                return .run { send in
                    async let events = persistence.events(hid)
                    async let members = persistence.members(hid)
                    await send(.eventsLoaded((try? await events) ?? []))
                    await send(.membersLoaded((try? await members) ?? []))
                    if let uid {
                        let prefs = try? await persistence.calendarSyncPrefs(uid)
                        await send(.prefsLoaded(prefs))
                    }
                    await send(.authStatusLoaded(status))
                }

            case let .eventsLoaded(events):
                state.isLoading = false
                state.events = events
                return .none

            case let .membersLoaded(members):
                state.members = members
                return .none

            case let .prefsLoaded(prefs):
                if let prefs { state.prefs = prefs }
                // Auto-sync on tab appear when setup is complete + enabled + we have access.
                if state.prefs.hasCompletedSetup, state.prefs.enabled, state.calendarAccessGranted {
                    return .send(.syncNow)
                }
                return .none

            case let .authStatusLoaded(status):
                state.accessStatus = status
                return .none

            case let .shiftMonth(delta):
                if let d = Calendar.current.date(byAdding: .month, value: delta, to: state.visibleMonth) {
                    state.visibleMonth = d
                }
                // Re-sync when the newly-visible month falls outside the last-synced window.
                let w = CalendarSyncEngine.window(for: state.visibleMonth)
                if state.prefs.hasCompletedSetup, state.prefs.enabled, state.calendarAccessGranted,
                   !state.prefs.windowCovered(start: w.start, end: w.end) {
                    return .send(.syncNow)
                }
                return .none

            case let .selectDate(date):
                state.selectedDate = Calendar.current.startOfDay(for: date)
                return .none

            case .addTapped:
                let start = defaultStart(on: state.selectedDate)
                state.form = EventFormReducer.State(
                    event: FamilyEvent(title: "", startDate: start, endDate: start.addingTimeInterval(3600)),
                    isEditing: false,
                    members: state.members
                )
                return .none

            case let .editTapped(event):
                state.form = EventFormReducer.State(event: event, isEditing: true, members: state.members)
                return .none

            case .form(.presented(.delegate(.didChange))):
                // A manual add/edit/delete — refresh, then push it to Apple if sync is live.
                if state.prefs.hasCompletedSetup, state.prefs.enabled, state.calendarAccessGranted {
                    return .merge(.send(.task), .send(.syncNow))
                }
                return .send(.task)

            case .form:
                return .none

            // MARK: Sync

            case .syncSettingsTapped:
                guard let uid = uid() else { return .none }
                state.syncSettings = CalendarSyncSettingsReducer.State(
                    userID: uid, prefs: state.prefs, accessStatus: state.accessStatus
                )
                return .none

            case let .syncSettings(.presented(.delegate(delegateAction))):
                switch delegateAction {
                case let .accessChanged(granted):
                    state.accessStatus = granted ? .granted : .denied
                    return .none
                case .completedSetup:
                    // First-run finished — dismiss the sheet, then refresh prefs (which auto-syncs).
                    state.syncSettings = nil
                    let uid = uid()
                    return .run { send in
                        if let uid {
                            let prefs = try? await persistence.calendarSyncPrefs(uid)
                            await send(.prefsLoaded(prefs))
                        }
                    }
                case .syncNow, .prefsChanged:
                    // Refresh prefs from Firestore (the sheet just wrote them); `.prefsLoaded` auto-syncs.
                    let uid = uid()
                    return .run { send in
                        if let uid {
                            let prefs = try? await persistence.calendarSyncPrefs(uid)
                            await send(.prefsLoaded(prefs))
                        }
                    }
                }

            case .syncSettings(.dismiss):
                // On sheet dismiss, pull the latest prefs and sync if live.
                let uid = uid()
                return .run { send in
                    if let uid {
                        let prefs = try? await persistence.calendarSyncPrefs(uid)
                        await send(.prefsLoaded(prefs))
                    }
                }

            case .syncSettings:
                return .none

            case .syncNow:
                guard state.calendarAccessGranted, state.prefs.enabled,
                      let hid = hid(), let uid = uid(),
                      !state.isSyncing else { return .none }
                state.isSyncing = true
                let prefs = state.prefs
                let visibleMonth = state.visibleMonth
                return .run { send in
                    let (updatedPrefs, events, error) = await Self.runSync(
                        hid: hid, uid: uid, prefs: prefs, visibleMonth: visibleMonth,
                        persistence: persistence, client: calendarSyncClient
                    )
                    await send(.syncFinished(prefs: updatedPrefs, events: events, error: error))
                }

            case let .syncFinished(prefs, events, error):
                state.isSyncing = false
                if let prefs { state.prefs = prefs }
                if let events { state.events = events }
                state.lastSyncError = error
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$form, action: \.form) {
            EventFormReducer()
        }
        .ifLet(\.$syncSettings, action: \.syncSettings) {
            CalendarSyncSettingsReducer()
        }
    }

    /// A start time on `day` at the current hour (so quick-add lands at a sensible time).
    private func defaultStart(on day: Date) -> Date {
        let cal = Calendar.current
        let now = cal.dateComponents([.hour], from: Date())
        return cal.date(bySettingHour: (now.hour ?? 9) + 1, minute: 0, second: 0, of: day) ?? day
    }

    // MARK: - Sync engine driver

    /// Runs the full three-phase sync + push for `visibleMonth`'s window. Pure orchestration over the
    /// injected clients; the classification lives in `CalendarSyncEngine.plan` (unit-tested). Returns
    /// the updated prefs (lastSynced + bacanCalendarID + window), reloaded events, and an error string
    /// (nil on success). Errors degrade silently in the UI — surfaced only in the settings footer.
    static func runSync(
        hid: String,
        uid: String,
        prefs initialPrefs: CalendarSyncPrefs,
        visibleMonth: Date,
        persistence: PersistenceClient,
        client: CalendarSyncClient
    ) async -> (prefs: CalendarSyncPrefs?, events: [FamilyEvent]?, error: String?) {
        var prefs = initialPrefs
        do {
            let window = CalendarSyncEngine.window(for: visibleMonth)

            // Ensure the dedicated Bacán push calendar (prefer the stored id).
            let bacanID = try await client.ensureBacanCalendar(prefs.bacanCalendarID)
            prefs.bacanCalendarID = bacanID

            // Resolve the enabled set (nil = all) from the opt-out list.
            var enabledIDs: Set<String>?
            if !prefs.disabledCalendarIDs.isEmpty {
                let all = try await client.availableCalendars()
                enabledIDs = Set(all.map(\.id)).subtracting(prefs.disabledCalendarIDs)
            }

            let existing = (try? await persistence.events(hid)) ?? []
            let imported = try await client.fetchWindow(window.start, window.end, bacanID, enabledIDs)

            // P2.2 auth gate: re-check EventKit access at sync time (it may have been revoked since the
            // tab loaded). Only a granted state may ever authorize destructive reconcile-deletes; the
            // engine additionally refuses to delete when the Apple fetch came back empty.
            let deletionsAllowed = client.authorizationStatus() == .granted

            let plan = CalendarSyncEngine.plan(
                existing: existing, imported: imported,
                windowStart: window.start, windowEnd: window.end,
                deletionsAllowed: deletionsAllowed
            )

            // Phases 1 & 2 — import new + update edited.
            for event in plan.toCreate { try await persistence.saveEvent(hid, event) }
            for event in plan.toUpdate { try await persistence.saveEvent(hid, event) }
            // Phase 3 — reconcile deletions of vanished imports.
            for id in plan.toDeleteImportIDs { try await persistence.deleteEvent(hid, id) }
            // Push — manual/email events into the Bacán calendar (recurring → true EK rule).
            for var event in plan.toPush {
                let ekID = try await client.saveEvent(event, bacanID)
                if event.eventKitIdentifier != ekID {
                    event.eventKitIdentifier = ekID
                    try await persistence.saveEvent(hid, event)
                }
            }

            prefs.lastSyncedAt = Date()
            prefs.lastSyncedWindowStart = window.start
            prefs.lastSyncedWindowEnd = window.end
            try? await persistence.saveCalendarSyncPrefs(uid, prefs)

            let refreshed = (try? await persistence.events(hid)) ?? existing
            return (prefs, refreshed, nil)
        } catch {
            // Persist bacanCalendarID progress even on failure so we don't re-create calendars.
            try? await persistence.saveCalendarSyncPrefs(uid, prefs)
            return (prefs, nil, error.localizedDescription)
        }
    }
}
