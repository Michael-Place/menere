import CalendarSyncClient
import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import UIKit

/// One sheet that does double duty (smallest clean): a warm first-run onboarding (value line →
/// permission → calendar picker) and, on return visits, the sync settings (master toggle, per-account
/// calendar toggles, Sync now, Last synced, Disconnect). Which face it shows is driven by
/// `prefs.hasCompletedSetup`.
@Reducer
public struct CalendarSyncSettingsReducer {
    @ObservableState
    public struct State: Equatable {
        public var userID: String
        public var prefs: CalendarSyncPrefs
        public var deviceCalendars: [DeviceCalendar] = []
        public var accessStatus: CalendarAuthStatus = .notDetermined
        public var isLoadingCalendars = false
        public var phase: Phase

        public init(userID: String, prefs: CalendarSyncPrefs, accessStatus: CalendarAuthStatus) {
            self.userID = userID
            self.prefs = prefs
            self.accessStatus = accessStatus
            self.phase = prefs.hasCompletedSetup ? .settings : .valueProposition
        }

        public enum Phase: Equatable {
            case valueProposition   // first-run: warm value line + Connect
            case picker             // first-run: calendars connected, choose which
            case settings           // return visits: full settings
        }

        public var groupedCalendars: [(accountName: String, calendars: [DeviceCalendar])] {
            let grouped = Dictionary(grouping: deviceCalendars, by: \.accountName)
            return grouped.keys.sorted().map { key in
                (accountName: key, calendars: grouped[key]!.sorted { $0.title < $1.title })
            }
        }
    }

    public enum Action: Equatable {
        case onAppear
        case prefsLoaded(CalendarSyncPrefs?)
        case calendarsLoaded([DeviceCalendar])
        case connectTapped
        case accessResult(Bool)
        case openSystemSettingsTapped
        case toggleCalendar(String)
        case setMasterEnabled(Bool)
        case startSyncingTapped
        case syncNowTapped
        case disconnectTapped
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case completedSetup          // first-run finished → parent syncs
            case syncNow                 // "Sync now" → parent syncs
            case accessChanged(Bool)     // permission result → parent learns granted state
            case prefsChanged            // toggles/master changed → parent should re-read + re-sync
        }
    }

    @Dependency(\.persistence) var persistence
    @Dependency(\.calendarSyncClient) var calendarClient

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                let uid = state.userID
                let alreadyGranted = state.accessStatus == .granted
                state.isLoadingCalendars = alreadyGranted
                return .run { send in
                    let prefs = try? await persistence.calendarSyncPrefs(uid)
                    await send(.prefsLoaded(prefs))
                    if alreadyGranted {
                        let cals = (try? await calendarClient.availableCalendars()) ?? []
                        await send(.calendarsLoaded(cals))
                    }
                }

            case let .prefsLoaded(prefs):
                if let prefs { state.prefs = prefs }
                return .none

            case let .calendarsLoaded(cals):
                state.deviceCalendars = cals
                state.isLoadingCalendars = false
                return .none

            case .connectTapped:
                return .run { send in
                    let granted = (try? await calendarClient.requestAccess()) ?? false
                    await send(.accessResult(granted))
                }

            case let .accessResult(granted):
                state.accessStatus = granted ? .granted : .denied
                if granted {
                    state.phase = .picker
                    state.isLoadingCalendars = true
                    return .merge(
                        .send(.delegate(.accessChanged(true))),
                        .run { send in
                            let cals = (try? await calendarClient.availableCalendars()) ?? []
                            await send(.calendarsLoaded(cals))
                        }
                    )
                }
                return .send(.delegate(.accessChanged(false)))

            case .openSystemSettingsTapped:
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                return .none

            case let .toggleCalendar(id):
                state.prefs.setEnabled(id, !state.prefs.isEnabled(id))
                return persistAndNotify(state.userID, state.prefs)

            case let .setMasterEnabled(on):
                state.prefs.enabled = on
                return persistAndNotify(state.userID, state.prefs)

            case .startSyncingTapped:
                state.prefs.hasCompletedSetup = true
                state.prefs.enabled = true
                let uid = state.userID
                let prefs = state.prefs
                return .run { send in
                    try? await persistence.saveCalendarSyncPrefs(uid, prefs)
                    await send(.delegate(.completedSetup))
                }

            case .syncNowTapped:
                // Optimistic "just now" so the footer updates immediately; the parent does the work.
                state.prefs.lastSyncedAt = Date()
                return .send(.delegate(.syncNow))

            case .disconnectTapped:
                // Friendly pause: turn sync off and forget the opt-out list, returning to the warm state.
                state.prefs.enabled = false
                state.prefs.hasCompletedSetup = false
                state.prefs.disabledCalendarIDs = []
                state.phase = .valueProposition
                let uid = state.userID
                let prefs = state.prefs
                return .run { send in
                    try? await persistence.saveCalendarSyncPrefs(uid, prefs)
                    await send(.delegate(.prefsChanged))
                }

            case .delegate:
                return .none
            }
        }
    }

    private func persistAndNotify(_ uid: String, _ prefs: CalendarSyncPrefs) -> Effect<Action> {
        .run { send in
            try? await persistence.saveCalendarSyncPrefs(uid, prefs)
            await send(.delegate(.prefsChanged))
        }
    }
}
