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
        .navigationTitle("Chores")
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
}
