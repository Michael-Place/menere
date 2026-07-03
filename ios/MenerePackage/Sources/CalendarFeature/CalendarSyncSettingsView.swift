import CalendarSyncClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI

public struct CalendarSyncSettingsView: View {
    @Bindable var store: StoreOf<CalendarSyncSettingsReducer>

    public init(store: StoreOf<CalendarSyncSettingsReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .valueProposition: valueProposition
                case .picker: picker
                case .settings: settings
                }
            }
            .background(Color.familyCanvas)
            .navigationTitle("Calendar sync")
            .navigationBarTitleDisplayMode(.inline)
            .task { store.send(.onAppear) }
        }
        .tint(.bacanGreen)
    }

    // MARK: First-run — value proposition

    private var valueProposition: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 56))
                .foregroundStyle(Color.bacanGreen)
            VStack(spacing: 8) {
                Text("One calendar for the whole circus.")
                    .font(.title2.bold())
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                Text("Connect your Apple calendars and everyone's plans land in one place — and anything Bacán adds shows up on your phone's calendar too.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Spacer()
            if store.accessStatus == .denied {
                deniedBlock
            } else {
                Button("Connect calendars") { store.send(.connectTapped) }
                    .buttonStyle(.borderedProminent)
                    .tint(.bacanGreen)
                    .controlSize(.large)
                    .accessibilityIdentifier("connect-calendars-button")
            }
        }
        .padding()
    }

    private var deniedBlock: some View {
        VStack(spacing: 8) {
            Text("Calendar access is off. Flip it on in Settings and we'll get in sync.")
                .font(.subheadline)
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
            Button("Open Settings") { store.send(.openSystemSettingsTapped) }
                .buttonStyle(.borderedProminent)
                .tint(.bacanGreen)
        }
        .padding(.bottom)
    }

    // MARK: First-run — picker

    private var picker: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.bacanGreen)
                Text("Connected!")
                    .font(.title3.bold())
                    .foregroundStyle(Color.ink)
                Text("Pick which calendars to fold in.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
            }
            .padding(.vertical)

            calendarList

            Button("Start syncing") { store.send(.startSyncingTapped) }
                .buttonStyle(.borderedProminent)
                .tint(.bacanGreen)
                .controlSize(.large)
                .padding()
                .accessibilityIdentifier("start-syncing-button")
        }
    }

    // MARK: Return visits — settings

    private var settings: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { store.prefs.enabled },
                    set: { store.send(.setMasterEnabled($0)) }
                )) {
                    Label("Sync with Apple Calendar", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.bacanGreen)
            } footer: {
                Text(lastSyncedText).foregroundStyle(Color.inkSoft)
            }

            if store.prefs.enabled {
                Section {
                    Button {
                        store.send(.syncNowTapped)
                    } label: {
                        Label("Sync now", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("sync-now-button")
                }

                calendarSections
            }

            Section {
                Button("Disconnect", role: .destructive) { store.send(.disconnectTapped) }
                    .accessibilityIdentifier("disconnect-button")
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Shared calendar list

    private var calendarList: some View {
        Group {
            if store.isLoadingCalendars {
                Spacer(); ProgressView(); Spacer()
            } else {
                List {
                    calendarSections
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    @ViewBuilder
    private var calendarSections: some View {
        ForEach(store.groupedCalendars, id: \.accountName) { group in
            Section(group.accountName) {
                ForEach(group.calendars) { cal in
                    Toggle(isOn: Binding(
                        get: { store.prefs.isEnabled(cal.id) },
                        set: { _ in store.send(.toggleCalendar(cal.id)) }
                    )) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color(hex: cal.colorHex) ?? .gray)
                                .frame(width: 12, height: 12)
                            Text(cal.title).foregroundStyle(Color.ink)
                        }
                    }
                    .tint(.bacanGreen)
                }
            }
        }
    }

    private var lastSyncedText: String {
        guard let last = store.prefs.lastSyncedAt else {
            return "Not synced yet."
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last synced \(f.localizedString(for: last, relativeTo: Date()))."
    }
}

extension Color {
    /// `#RRGGBB` → Color (nil on malformed input).
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
