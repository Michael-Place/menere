import ComposableArchitecture
import FamilyDomain
import MenereUI
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

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        case eventsLoaded([FamilyEvent])
        case membersLoaded([HouseholdMember])
        case shiftMonth(Int)
        case selectDate(Date)
        case addTapped
        case editTapped(FamilyEvent)
        case form(PresentationAction<EventFormReducer.Action>)
        case binding(BindingAction<State>)
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                state.isLoading = true
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    async let events = persistence.events(hid)
                    async let members = persistence.members(hid)
                    await send(.eventsLoaded((try? await events) ?? []))
                    await send(.membersLoaded((try? await members) ?? []))
                }

            case let .eventsLoaded(events):
                state.isLoading = false
                state.events = events
                return .none

            case let .membersLoaded(members):
                state.members = members
                return .none

            case let .shiftMonth(delta):
                if let d = Calendar.current.date(byAdding: .month, value: delta, to: state.visibleMonth) {
                    state.visibleMonth = d
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
                return .send(.task)

            case .form:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$form, action: \.form) {
            EventFormReducer()
        }
    }

    /// A start time on `day` at the current hour (so quick-add lands at a sensible time).
    private func defaultStart(on day: Date) -> Date {
        let cal = Calendar.current
        let now = cal.dateComponents([.hour], from: Date())
        return cal.date(bySettingHour: (now.hour ?? 9) + 1, minute: 0, second: 0, of: day) ?? day
    }
}
