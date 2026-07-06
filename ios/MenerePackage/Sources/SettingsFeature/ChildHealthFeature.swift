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
        /// This household's memories (loaded on appear) — the source for deriving milestone achievement.
        var memories: [Memory] = []
        /// The achieved-milestone row currently expanded to reveal its memory (nil = all collapsed).
        var expandedMemoryId: String?

        public init(member: HouseholdMember) {
            self.member = member
            let fallback = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
            self.draftBirthdate = member.birthdate ?? fallback
            self.isEditingBirthday = member.birthdate == nil
        }

        /// The resolved child-health schedule, or nil until a birthday is set.
        var schedule: ChildSchedule? { ChildCareKB.schedule(for: member) }

        /// One KB milestone this kid has **reached** — derived (no schema churn) by matching a memory's
        /// `milestone` tag to a ``ChildCareKB`` milestone. Carries the memory for the date + deep-link.
        public struct AchievedMilestone: Equatable, Identifiable, Sendable {
            /// The KB prose that was matched ("First words (around 12 months — log it!)").
            public let milestone: String
            /// The memory that recorded it.
            public let memory: Memory
            public var id: String { memory.id + "|" + milestone }
            public var date: Date { memory.date }
        }

        /// The milestones this kid has reached — derived by scanning their tagged memories for a
        /// `milestone` that matches any ``ChildCareKB`` milestone. De-duplicated by milestone (the
        /// **earliest** memory wins — the true first time), then shown most-recent-first.
        var achievedMilestones: [AchievedMilestone] {
            let kidMemories = memories
                .filter { $0.kidMemberIds.contains(member.id) && !($0.milestone ?? "").isEmpty }
                .sorted { $0.date < $1.date }
            let pool = ChildCareKB.allMilestones
            var seenTags = Set<String>()
            var result: [AchievedMilestone] = []
            for memory in kidMemories {
                guard let ms = memory.milestone,
                      let kb = pool.first(where: { ChildCareKB.milestonesMatch($0, ms) }) else { continue }
                let tag = ChildCareKB.milestoneTag(for: kb).lowercased()
                if seenTags.insert(tag).inserted {
                    result.append(AchievedMilestone(milestone: kb, memory: memory))
                }
            }
            return result.sorted { $0.date > $1.date }
        }

        /// The current age band's milestones this kid **hasn't** logged yet — the "still to watch" list.
        var milestonesToWatch: [String] {
            guard let toWatch = schedule?.milestonesToWatch else { return [] }
            let achievedTags = Set(achievedMilestones.map { ChildCareKB.milestoneTag(for: $0.milestone).lowercased() })
            return toWatch.filter { !achievedTags.contains(ChildCareKB.milestoneTag(for: $0).lowercased()) }
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case memoriesLoaded([Memory])
        case achievedMilestoneTapped(memoryId: String)
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
                guard let hid = hid() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let memories = (try? await persistence.memories(hid)) ?? []
                    await send(.memoriesLoaded(memories))
                }

            case let .memoriesLoaded(memories):
                state.memories = memories
                return .none

            case let .achievedMilestoneTapped(memoryId):
                state.expandedMemoryId = state.expandedMemoryId == memoryId ? nil : memoryId
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
        let achieved = store.achievedMilestones
        let toWatch = store.milestonesToWatch
        if !achieved.isEmpty || !toWatch.isEmpty {
            card {
                VStack(alignment: .leading, spacing: 14) {
                    sectionLabel(
                        schedule.milestoneBandLabel.map { "Milestones · \($0)" } ?? "Milestones",
                        systemImage: "sparkles"
                    )

                    if !achieved.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Reached 🎉")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Color.bacanGreen)
                            ForEach(achieved) { achievedRow($0) }
                        }
                    }

                    if !toWatch.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !achieved.isEmpty {
                                Text("Still to watch")
                                    .font(.subheadline.weight(.bold)).foregroundStyle(Color.inkSoft)
                            }
                            ForEach(toWatch, id: \.self) { milestone in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(tint)
                                        .padding(.top, 6)
                                    Text(milestone).font(.subheadline).foregroundStyle(Color.ink)
                                }
                            }
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

    /// One reached milestone — a check, the milestone name, a warm "Famfis · Jul 5 🎉" line, and a
    /// tap-to-reveal peek at the memory that recorded it (title + story + full date).
    @ViewBuilder
    private func achievedRow(_ item: ChildHealthReducer.State.AchievedMilestone) -> some View {
        let expanded = store.expandedMemoryId == item.memory.id
        VStack(alignment: .leading, spacing: 6) {
            Button {
                store.send(.achievedMilestoneTapped(memoryId: item.memory.id), animation: .snappy)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(Color.bacanGreen)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ChildCareKB.milestoneTag(for: item.milestone))
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                        Text(achievedCaption(item))
                            .font(.caption).foregroundStyle(Color.bacanGreen)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold)).foregroundStyle(Color.inkSoft)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .padding(.top, 3)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("achieved-milestone-\(item.memory.id)")

            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = item.memory.title, !title.isEmpty {
                        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color.ink)
                    }
                    if !item.memory.plainStory.isEmpty {
                        Text(item.memory.plainStory)
                            .font(.caption).foregroundStyle(Color.inkSoft).lineLimit(4)
                    }
                    Label(
                        item.memory.date.formatted(.dateTime.weekday(.wide).month(.wide).day().year()),
                        systemImage: "book.pages"
                    )
                    .font(.caption2).foregroundStyle(Color.inkSoft)
                }
                .padding(.leading, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// "Famfis · Jul 5 🎉" — the warm subtitle under a reached milestone.
    private func achievedCaption(_ item: ChildHealthReducer.State.AchievedMilestone) -> String {
        let name = member.name.split(separator: " ").first.map(String.init) ?? member.name
        let day = item.memory.date.formatted(.dateTime.month(.abbreviated).day())
        return "\(name) · \(day) 🎉"
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
