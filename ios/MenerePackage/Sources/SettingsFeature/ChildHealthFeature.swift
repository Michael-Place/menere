import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// P31 — the per-kid **Health schedule** surface. Informational, read-mostly: a child's age, their next
/// well-child visit (dated off their birthday), upcoming vaccines/dental/screenings, and a few
/// developmental milestones to watch with a gentle "log it in Memories" nudge. When no birthday is set
/// yet it shows a "set birthday" prompt. Sourced entirely from ``ChildCareKB`` — a general guide, never
/// medical advice.
@Reducer
public struct ChildHealthReducer {
    @ObservableState
    public struct State: Equatable {
        var member: HouseholdMember
        /// The birthday being edited (defaults to the member's, or ~1yr ago as a friendly starting point).
        var draftBirthdate: Date
        /// True while the birthday picker is expanded (auto-true when no birthday is set yet).
        var isEditingBirthday: Bool
        var isSaving = false

        public init(member: HouseholdMember) {
            self.member = member
            let fallback = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            self.draftBirthdate = member.birthdate ?? fallback
            self.isEditingBirthday = member.birthdate == nil
        }

        /// The resolved child-health schedule, or nil until a birthday is set.
        var schedule: ChildSchedule? { ChildCareKB.schedule(for: member) }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case doneTapped
        case editBirthdayTapped
        case saveBirthdayTapped
        case cancelBirthdayEdit
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case saved(HouseholdMember) }
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
            case .task:
                @Dependency(\.analytics) var analytics
                analytics.log("child_schedule_viewed")
                return .none

            case .doneTapped:
                return .run { _ in await dismiss() }

            case .editBirthdayTapped:
                state.draftBirthdate = state.member.birthdate ?? state.draftBirthdate
                state.isEditingBirthday = true
                return .none

            case .cancelBirthdayEdit:
                // Only collapsible once a birthday exists — otherwise the prompt stays put.
                if state.member.birthdate != nil { state.isEditingBirthday = false }
                return .none

            case .saveBirthdayTapped:
                guard let hid = hid(), !state.isSaving else { return .none }
                state.isSaving = true
                state.member.birthdate = state.draftBirthdate
                state.isEditingBirthday = false
                let member = state.member
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.saveMember(hid, member)
                    await send(.delegate(.saved(member)))
                }

            case .delegate, .binding:
                state.isSaving = false
                return .none
            }
        }
    }
}

public struct ChildHealthView: View {
    @Bindable var store: StoreOf<ChildHealthReducer>

    public init(store: StoreOf<ChildHealthReducer>) {
        self.store = store
    }

    private var member: HouseholdMember { store.member }
    private var tint: Color {
        let rgb = member.color.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    if store.isEditingBirthday {
                        birthdayEditor
                    }

                    if let schedule = store.schedule {
                        nextVisitCard(schedule)
                        upcomingCard(schedule)
                        milestonesCard(schedule)
                        disclaimer
                    } else if !store.isEditingBirthday {
                        setBirthdayPrompt
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Health schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.doneTapped) }
                        .accessibilityIdentifier("child-health-done-button")
                }
            }
            .task { store.send(.task) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: member.avatarSystemName)
                .font(.system(size: 44))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name).font(.title2.bold()).foregroundStyle(Color.ink)
                if let age = member.ageDescription() {
                    Text(age).font(.subheadline).foregroundStyle(Color.inkSoft)
                } else {
                    Text("No birthday yet").font(.subheadline).foregroundStyle(Color.inkSoft)
                }
            }
            Spacer()
            if member.birthdate != nil, !store.isEditingBirthday {
                Button {
                    store.send(.editBirthdayTapped)
                } label: {
                    Image(systemName: "calendar.badge.clock").foregroundStyle(Color.bacanGreen)
                }
                .accessibilityIdentifier("edit-birthday-button")
                .accessibilityLabel("Edit birthday")
            }
        }
    }

    // MARK: - Birthday editing

    private var birthdayEditor: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(member.birthdate == nil ? "When's \(member.name)'s birthday?" : "\(member.name)'s birthday")
                    .font(.headline).foregroundStyle(Color.ink)
                DatePicker(
                    "Birthday",
                    selection: $store.draftBirthdate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(Color.bacanGreen)
                .accessibilityIdentifier("birthday-date-picker")
                Button {
                    store.send(.saveBirthdayTapped)
                } label: {
                    Text("Save birthday")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.bacanGreen, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("save-birthday-button")
            }
        }
    }

    private var setBirthdayPrompt: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set \(member.name)'s birthday")
                    .font(.headline).foregroundStyle(Color.ink)
                Text("Add a birthday and Bacán will map out \(member.name)'s well-child visits, shots, and milestones to watch for.")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
                Button {
                    store.send(.editBirthdayTapped)
                } label: {
                    Label("Set birthday", systemImage: "birthday.cake.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.bacanGreen, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("set-birthday-button")
            }
        }
    }

    // MARK: - Schedule cards

    private func nextVisitCard(_ schedule: ChildSchedule) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Next well-child visit", systemImage: "stethoscope")
                if let visit = schedule.nextWellVisit, let date = date(atAgeMonths: visit.ageMonths) {
                    Text(visit.label).font(.title3.bold()).foregroundStyle(Color.ink)
                    Text("around \(date, format: .dateTime.month(.wide).year())")
                        .font(.subheadline).foregroundStyle(Color.bacanGreen)
                    Text("Bring the vaccine record — vision & hearing get checked here too.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("All the well-child visits are behind you — annual checkups from here.")
                        .font(.subheadline).foregroundStyle(Color.inkSoft)
                }
            }
        }
    }

    @ViewBuilder
    private func upcomingCard(_ schedule: ChildSchedule) -> some View {
        if !schedule.upcomingItems.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("Coming up", systemImage: "calendar")
                    ForEach(schedule.upcomingItems) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.category.iconSymbol)
                                .foregroundStyle(tint)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                                    Spacer()
                                    if let date = date(atAgeMonths: item.ageMonths) {
                                        Text(date, format: .dateTime.month(.abbreviated).year())
                                            .font(.caption).foregroundStyle(Color.inkSoft)
                                    }
                                }
                                Text(item.note).font(.caption).foregroundStyle(Color.inkSoft)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func milestonesCard(_ schedule: ChildSchedule) -> some View {
        if !schedule.milestonesToWatch.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel(
                        schedule.milestoneBandLabel.map { "Milestones to watch · \($0)" } ?? "Milestones to watch",
                        systemImage: "sparkles"
                    )
                    ForEach(schedule.milestonesToWatch, id: \.self) { milestone in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(tint)
                                .padding(.top, 6)
                            Text(milestone).font(.subheadline).foregroundStyle(Color.ink)
                        }
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "heart.text.square.fill").foregroundStyle(Color.marigold)
                        Text("Catch one of these? Log it in Memories — future you will thank you.")
                            .font(.caption).foregroundStyle(Color.inkSoft)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private var disclaimer: some View {
        Text(ChildSchedule.disclaimer)
            .font(.caption2)
            .foregroundStyle(Color.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.inkSoft)
            .textCase(.uppercase)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.ink.opacity(0.08), lineWidth: 1))
    }

    /// The calendar date a child hits `ageMonths` — birthday plus that many months.
    private func date(atAgeMonths ageMonths: Int) -> Date? {
        guard let birthdate = member.birthdate else { return nil }
        return Calendar.current.date(byAdding: .month, value: ageMonths, to: birthdate)
    }
}
