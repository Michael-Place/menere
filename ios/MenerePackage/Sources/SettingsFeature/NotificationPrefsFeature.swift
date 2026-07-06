import ComposableArchitecture
import FamilyDomain
import Foundation
import MenereUI
import PersistenceClient
import SwiftUI

// MARK: - Reducer

/// "Notifications" (Act V V2-E) — the household's proactive-notification preferences sheet. Governs
/// the **weekly family digest** and the daily **"your 3 things"** nudge (both delivered by scheduled
/// Cloud Functions that read the very same `households/{hid}/config/notificationPrefs` doc). Loads the
/// prefs on appear and persists every edit (full-doc write, mirroring the smart-home / budget config
/// saves). Self-contained (its own reducer + view, like the wishlist / usage-review sheets) so it
/// plugs into Settings additively.
@Reducer
public struct NotificationPrefsReducer {
    @ObservableState
    public struct State: Equatable {
        /// The household whose prefs we edit (the scheduled functions key off this same hid).
        public var hid: String
        public var prefs: NotificationPrefs
        /// True once the stored prefs have loaded — gates the auto-save so the initial load doesn't
        /// immediately write defaults back over a hand-set doc.
        var isLoaded = false

        public init(hid: String, prefs: NotificationPrefs = NotificationPrefs()) {
            self.hid = hid
            self.prefs = prefs
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case prefsLoaded(NotificationPrefs?)
        case binding(BindingAction<State>)
    }

    public init() {}

    @Dependency(\.persistence) var persistence

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard !state.isLoaded else { return .none }
                let hid = state.hid
                return .run { send in
                    let loaded = try? await persistence.notificationPrefs(hid)
                    await send(.prefsLoaded(loaded))
                }

            case let .prefsLoaded(loaded):
                if let loaded { state.prefs = loaded }
                state.isLoaded = true
                return .none

            case .binding:
                // Persist every edit. Only after the initial load so we never clobber the stored doc
                // with defaults on first appearance.
                guard state.isLoaded else { return .none }
                let hid = state.hid
                let prefs = state.prefs
                return .run { _ in
                    try? await persistence.saveNotificationPrefs(hid, prefs)
                }
            }
        }
    }
}

// MARK: - View

public struct NotificationPrefsView: View {
    @Bindable var store: StoreOf<NotificationPrefsReducer>

    public init(store: StoreOf<NotificationPrefsReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                introSection
                weeklyDigestSection
                dailyNudgeSection
                quietHoursSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .tint(Color.bacanGreen)
            .task { store.send(.task) }
        }
    }

    private var introSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(Color.bacanGreen)
                Text("Bacán only nudges you when there's something worth saying — quiet by design.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .listRowBackground(Color.familyCanvas)
        }
    }

    private var weeklyDigestSection: some View {
        Section {
            Toggle(isOn: $store.prefs.weeklyDigestEnabled) {
                Label("Weekly family digest", systemImage: "calendar.badge.clock")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("weekly-digest-toggle")
            .listRowBackground(Color.familyCanvas)

            if store.prefs.weeklyDigestEnabled {
                Picker(selection: $store.prefs.weeklyDigestWeekday) {
                    ForEach(NotificationPrefs.weekdayChoices, id: \.weekday) { choice in
                        Text(choice.name).tag(choice.weekday)
                    }
                } label: {
                    Label("Delivery day", systemImage: "calendar")
                        .foregroundStyle(Color.ink)
                }
                .accessibilityIdentifier("weekly-digest-day-picker")
                .listRowBackground(Color.familyCanvas)
            }
        } header: {
            Text("Weekly digest")
        } footer: {
            Text("A warm Sunday-style rundown of the week ahead — care that's due, renewals, birthdays, what's on the calendar, and a money glance.")
        }
    }

    private var dailyNudgeSection: some View {
        Section {
            Toggle(isOn: $store.prefs.dailyNudgeEnabled) {
                Label("Your 3 things", systemImage: "checklist")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("daily-nudge-toggle")
            .listRowBackground(Color.familyCanvas)
        } header: {
            Text("Daily nudge")
        } footer: {
            Text("Each morning, up to three of the most useful things — an overdue plant, a checkup, a birthday to shop for. Nothing pressing? No nudge.")
        }
    }

    private var quietHoursSection: some View {
        Section {
            Toggle(isOn: $store.prefs.quietHoursEnabled) {
                Label("Quiet hours", systemImage: "moon.fill")
                    .foregroundStyle(Color.ink)
            }
            .accessibilityIdentifier("quiet-hours-toggle")
            .listRowBackground(Color.familyCanvas)

            if store.prefs.quietHoursEnabled {
                hourPicker("From", selection: $store.prefs.quietHoursStart, id: "quiet-hours-start")
                hourPicker("To", selection: $store.prefs.quietHoursEnd, id: "quiet-hours-end")
            }
        } header: {
            Text("Quiet hours")
        } footer: {
            Text("Hold any nudges during these hours. Off by default — the digest and daily nudge already arrive at a civil hour.")
        }
    }

    private func hourPicker(_ title: String, selection: Binding<Int>, id: String) -> some View {
        Picker(selection: selection) {
            ForEach(0..<24, id: \.self) { hour in
                Text(NotificationPrefs.hourLabel(hour)).tag(hour)
            }
        } label: {
            Text(title).foregroundStyle(Color.ink)
        }
        .accessibilityIdentifier(id)
        .listRowBackground(Color.familyCanvas)
    }
}
