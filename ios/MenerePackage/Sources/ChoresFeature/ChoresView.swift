import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI
import UserDomain

public struct ChoresView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    public init(store: StoreOf<ChoresReducer>) {
        self.store = store
    }

    public var body: some View {
        List {
            Section("House care") {
                if store.careItems.isEmpty {
                    if store.careSuggestionsDismissed {
                        Text("Nothing under care yet — add the first thing you always forget.")
                            .foregroundStyle(Color.inkSoft)
                    } else {
                        careSuggestionsCard
                    }
                } else {
                    ForEach(store.careItems) { item in
                        CareRow(
                            item: item,
                            members: store.members,
                            onEdit: { store.send(.editCareItemTapped(item)) },
                            onMarkDone: { taskID in
                                store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
                            }
                        )
                    }
                }
                Button {
                    store.send(.addCareItemTapped)
                } label: {
                    Label("Add a care item", systemImage: "plus")
                        .appearBounce()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("add-care-item-button")
            }
            .listRowBackground(Color.familySurface)

            if !store.activity.isEmpty {
                Section("Recent Activity") {
                    ForEach(store.activity.prefix(5)) { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.systemImage).foregroundStyle(Color.bacanGreen)
                            Text(item.text).font(.callout).foregroundStyle(Color.ink)
                        }
                    }
                }
                .listRowBackground(Color.familySurface)
            }

            if !store.members.isEmpty {
                Section("Leaderboard") {
                    ForEach(leaderboard) { row in
                        leaderboardRow(row)
                    }
                }
                .listRowBackground(Color.familySurface)
            }

            Section("Chores") {
                if store.chores.isEmpty, store.isLoading {
                    ProgressView()
                } else if store.chores.isEmpty {
                    Text("No chores on the board — tap + to add one.")
                        .foregroundStyle(Color.inkSoft)
                } else {
                    ForEach(store.chores) { chore in
                        choreRow(chore)
                    }
                }
            }
            .listRowBackground(Color.familySurface)

            Section {
                ForEach(store.rewards) { reward in
                    rewardRow(reward)
                }
                Button {
                    store.send(.addRewardTapped)
                } label: {
                    Label("Add reward", systemImage: "plus")
                        .appearBounce()
                }
                .buttonStyle(.pressable)
            } header: {
                Text("Rewards")
            } footer: {
                Text("Redeeming spends your hard-earned XP. Choose wisely.")
            }
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .overlay {
            // Member-colored celebration when the live leaderboard reports a level-up.
            ConfettiBurst(color: confettiColor, trigger: store.confettiTrigger)
                .ignoresSafeArea()
        }
        .navigationTitle("Home")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("add-chore-button")
            }
        }
        .task { store.send(.task) }
        .sheet(item: $store.scope(state: \.form, action: \.form)) { formStore in
            ChoreFormView(store: formStore)
        }
        .sheet(item: $store.scope(state: \.careForm, action: \.careForm)) { formStore in
            CareItemFormView(store: formStore)
        }
        .alert("New reward", isPresented: $store.showAddReward) {
            TextField("What's the prize?", text: $store.newRewardTitle)
            TextField("XP cost", value: $store.newRewardCost, format: .number)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { store.showAddReward = false }
            Button("Add") { store.send(.createReward) }
        }
    }

    /// The confetti color for the most recent level-up (falls back to the brand green).
    private var confettiColor: Color {
        guard let mc = store.confettiColor else { return .bacanGreen }
        let rgb = mc.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: Leaderboard

    private struct LeaderRow: Identifiable, Equatable {
        let member: HouseholdMember
        let stats: MemberStats
        var id: String { member.id }
    }

    /// View-local lookup — `store.stats` resolves to the state property, so the state's
    /// `stats(for:)` method isn't reachable through the store.
    private func memberStats(for id: String) -> MemberStats {
        store.stats.first { $0.memberID == id } ?? MemberStats(id: id, memberID: id)
    }

    private var leaderboard: [LeaderRow] {
        store.members
            .map { LeaderRow(member: $0, stats: memberStats(for: $0.id)) }
            .sorted { $0.stats.totalXP > $1.stats.totalXP }
    }

    private func leaderboardRow(_ row: LeaderRow) -> some View {
        let rgb = row.member.color.rgb
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: row.member.avatarSystemName).foregroundStyle(color)
                Text(row.member.name).foregroundStyle(Color.ink)
                Spacer()
                Text("Lv \(row.stats.level)")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.inkSoft)
                Text("\(row.stats.totalXP) XP")
                    .font(.caption).foregroundStyle(color)
            }
            ProgressView(value: row.stats.levelProgress).tint(color)
        }
        .padding(.vertical, 2)
    }

    // MARK: Chores

    private func choreRow(_ chore: Chore) -> some View {
        HStack(spacing: 12) {
            Button { store.send(.toggleComplete(chore)) } label: {
                Image(systemName: chore.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chore.isCompleted ? Color.bacanGreen : Color.inkSoft)
                    .stickerSlap(isOn: chore.isCompleted, color: .bacanGreen)
            }
            .buttonStyle(.pressable)

            Button { store.send(.editTapped(chore)) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chore.title)
                        .strikethrough(chore.isCompleted)
                        .foregroundStyle(chore.isCompleted ? Color.inkSoft : Color.ink)
                    HStack(spacing: 6) {
                        Label("\(chore.effectiveXP) XP", systemImage: chore.difficulty.icon)
                            .font(.caption2).foregroundStyle(Color.inkSoft)
                        if let assignee = store.members.first(where: { $0.id == chore.assigneeID }) {
                            Text("· \(assignee.name)").font(.caption2).foregroundStyle(Color.inkSoft)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: Rewards

    private func rewardRow(_ reward: Reward) -> some View {
        HStack {
            Label(reward.title, systemImage: reward.iconName)
                .foregroundStyle(Color.ink)
            Spacer()
            Text("\(reward.xpCost) XP").font(.caption).foregroundStyle(Color.inkSoft)
            Menu {
                ForEach(store.members) { member in
                    let stats = memberStats(for: member.id)
                    Button {
                        store.send(.redeem(reward, byMemberID: member.id))
                    } label: {
                        Text("\(member.name) (\(stats.totalXP) XP)")
                    }
                    .disabled(stats.totalXP < reward.xpCost)
                }
            } label: {
                Text("Redeem").font(.caption).fontWeight(.semibold).foregroundStyle(Color.bacanGreen)
            }
        }
    }

    // MARK: House care

    private var careSuggestionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get a head start")
                .font(.headline).foregroundStyle(Color.ink)
            Text("Tap to add the stuff that's easy to forget. Edit anytime.")
                .font(.caption).foregroundStyle(Color.inkSoft)
            ForEach(CareSuggestion.starters) { suggestion in
                Button {
                    store.send(.careSuggestionTapped(suggestion))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.icon)
                            .foregroundStyle(Color.bacanGreen)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.name).foregroundStyle(Color.ink)
                            Text(CareItem.intervalLabel(suggestion.intervalDays))
                                .font(.caption2).foregroundStyle(Color.inkSoft)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.bacanGreen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("care-suggestion-\(suggestion.id)")
            }
            Button("No thanks, I'll add my own") {
                store.send(.dismissCareSuggestions)
            }
            .font(.caption).foregroundStyle(Color.inkSoft)
            .accessibilityIdentifier("dismiss-care-suggestions")
        }
        .padding(.vertical, 4)
    }
}

/// A single House-care row: icon + name/location + the soonest task's due line, with a sticker-slap
/// "Mark done" affordance. Its own `View` struct so the slap owns a `@State` trigger that replays on
/// every tap. Tapping the label opens the item's form (all tasks visible there).
private struct CareRow: View {
    let item: CareItem
    let members: [HouseholdMember]
    let onEdit: () -> Void
    let onMarkDone: (_ taskID: String) -> Void

    @State private var slapOn = false

    private var soonest: CareTask? { item.soonestDueTask() }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.bacanGreen.opacity(0.15))
                Image(systemName: item.iconSymbol).foregroundStyle(Color.bacanGreen)
            }
            .frame(width: 40, height: 40)

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(Color.ink)
                    if let location = item.location, !location.isEmpty {
                        Text(location).font(.caption2).foregroundStyle(Color.inkSoft)
                    }
                    dueLine
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if let task = soonest {
                Button {
                    onMarkDone(task.id)
                    slapOn = true
                    Task { try? await Task.sleep(for: .milliseconds(700)); slapOn = false }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.bacanGreen)
                        .stickerSlap(isOn: slapOn, color: .bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Mark done")
                .accessibilityIdentifier("care-mark-done-\(item.id)")
            }
        }
    }

    /// Due line copy + color. Domain gives the day math; the view owns thresholds & voice.
    @ViewBuilder
    private var dueLine: some View {
        if let task = soonest {
            let days = task.daysUntilDue()
            if days == nil {
                // Seasonal / manual.
                if task.lastDoneAt != nil {
                    Text(doneText(task)).font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("Seasonal · mark it when you do it").font(.caption).foregroundStyle(Color.inkSoft)
                }
            } else if let d = days, d < 0 {
                Text("Overdue by \(-d) day\(-d == 1 ? "" : "s")")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.terracotta)
            } else if days == 0 {
                Text("Due today").font(.caption).fontWeight(.semibold).foregroundStyle(Color.bacanGreen)
            } else if let d = days, d <= 14 {
                Text("Due in \(d) day\(d == 1 ? "" : "s")").font(.caption).foregroundStyle(Color.inkSoft)
            } else if let d = days {
                // Due far out — reassure with who handled it last, if anyone.
                if task.lastDoneAt != nil {
                    Text(doneText(task)).font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("Due in \(d) days").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
        } else {
            Text("No tasks yet — tap to add one").font(.caption).foregroundStyle(Color.inkSoft)
        }
    }

    private func doneText(_ task: CareTask) -> String {
        guard let last = task.lastDoneAt else { return "" }
        let date = last.formatted(.dateTime.month(.abbreviated).day())
        if let by = task.lastDoneBy, let name = members.first(where: { $0.id == by })?.name {
            return "Done \(date) by \(name)"
        }
        return "Done \(date)"
    }
}
