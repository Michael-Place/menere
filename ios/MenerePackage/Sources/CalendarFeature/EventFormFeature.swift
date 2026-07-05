import AnalyticsClient
import CalendarSyncClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

@Reducer
public struct EventFormReducer {
    @ObservableState
    public struct State: Equatable {
        var event: FamilyEvent
        let isEditing: Bool
        var members: [HouseholdMember]

        public init(event: FamilyEvent, isEditing: Bool, members: [HouseholdMember]) {
            self.event = event
            self.isEditing = isEditing
            self.members = members
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case deleteTapped
        case toggleAssignee(String)
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable {
            case didChange
        }
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding(\.event.isAllDay):
                // Keep end date sane when toggling all-day off.
                if !state.event.isAllDay, state.event.endDate == nil {
                    state.event.endDate = state.event.startDate.addingTimeInterval(3600)
                }
                return .none

            case .binding:
                return .none

            case let .toggleAssignee(id):
                if let idx = state.event.assigneeIDs.firstIndex(of: id) {
                    state.event.assigneeIDs.remove(at: idx)
                } else {
                    state.event.assigneeIDs.append(id)
                }
                return .none

            case .saveTapped:
                guard let hid = hid(),
                      !state.event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                state.event.updatedAt = Date()
                let event = state.event
                let isNew = !state.isEditing
                if isNew {
                    @Dependency(\.analytics) var analytics
                    analytics.log("event_added")   // P25 telemetry (fire-and-forget)
                }
                @Shared(.user) var user
                let actorID = user?.id
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveEvent(hid, event)
                    if isNew {
                        try? await persistence.logActivity(hid, .eventAdded(title: event.title, actorID: actorID))
                    }
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .deleteTapped:
                guard let hid = hid() else { return .none }
                let id = state.event.id
                // Propagate deletes of Bacán-origin (manual/email) events to their Apple mirror. Imported
                // events are left alone (deleting the Apple original from a mirror would be too destructive;
                // they simply re-import on the next sync).
                let ekIDToDelete = state.event.resolvedSource != .calendarImport ? state.event.eventKitIdentifier : nil
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.calendarSyncClient) var calendarSyncClient
                    try await persistence.deleteEvent(hid, id)
                    if let ekIDToDelete {
                        try? await calendarSyncClient.deleteEvent(ekIDToDelete)
                    }
                    await send(.delegate(.didChange))
                    await dismiss()
                }

            case .delegate:
                return .none
            }
        }
    }
}

public struct EventFormView: View {
    @Bindable var store: StoreOf<EventFormReducer>

    public init(store: StoreOf<EventFormReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $store.event.title)
                        .accessibilityIdentifier("event-title-field")
                    Toggle("All day", isOn: $store.event.isAllDay)
                    DatePicker(
                        "Starts",
                        selection: $store.event.startDate,
                        displayedComponents: store.event.isAllDay ? [.date] : [.date, .hourAndMinute]
                    )
                    if !store.event.isAllDay {
                        DatePicker(
                            "Ends",
                            selection: Binding(
                                get: { store.event.endDate ?? store.event.startDate.addingTimeInterval(3600) },
                                set: { store.event.endDate = $0 }
                            ),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("Repeat") {
                    Picker("Repeats", selection: $store.event.recurrence) {
                        ForEach(RecurrenceOption.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                if !store.members.isEmpty {
                    Section("Who") {
                        ForEach(store.members) { member in
                            Button {
                                store.send(.toggleAssignee(member.id))
                            } label: {
                                HStack {
                                    let rgb = member.color.rgb
                                    Circle()
                                        .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                                        .frame(width: 12, height: 12)
                                    Text(member.name).foregroundStyle(Color.ink)
                                    Spacer()
                                    if store.event.assigneeIDs.contains(member.id) {
                                        Image(systemName: "checkmark").foregroundStyle(Color.bacanGreen)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Details") {
                    TextField("Location", text: Binding(
                        get: { store.event.location ?? "" },
                        set: { store.event.location = $0.isEmpty ? nil : $0 }
                    ))
                }

                // Rich-Text C2 — the family's own event notes, bound to `familyNotes` (NOT `notes`,
                // which CalendarSyncEngine mirrors to/from Apple Calendar). Persists via the existing
                // event save.
                Section("Notes") {
                    RichNoteEditor(
                        markdown: Binding(
                            get: { store.event.familyNotes ?? "" },
                            set: { store.event.familyNotes = $0.isEmpty ? nil : $0 }
                        ),
                        placeholder: "Add a note about this event…"
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if store.isEditing {
                    Section {
                        Button("Delete Event", role: .destructive) { store.send(.deleteTapped) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(store.isEditing ? "Edit Event" : "New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("save-event-button")
                }
            }
        }
    }
}
