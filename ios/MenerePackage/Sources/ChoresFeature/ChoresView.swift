import ComposableArchitecture
import DocsFeature
import FamilyDomain
import MenereUI
import SwiftUI
import UIKit
import UserDomain

public struct ChoresView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    public init(store: StoreOf<ChoresReducer>) {
        self.store = store
    }

    /// Whole-house upkeep — the House-care section's rows (P9-C3 split zones out into their own).
    private var houseItems: [CareItem] { store.careItems.filter { $0.kind == .house } }
    /// Plant care items — the Plants section's rows.
    private var plantItems: [CareItem] { store.careItems.filter { $0.kind == .plant } }
    /// Yard & garden zones — the seasonal-landscaping section's rows (P9-C3).
    private var zoneItems: [CareItem] { store.careItems.filter { $0.kind == .zone } }
    /// Pets — Fajita, Sprinkle, and friends (P10).
    private var petItems: [CareItem] { store.careItems.filter { $0.kind == .pet } }

    public var body: some View {
        List {
            Section("House care") {
                // The health banner is kind-agnostic: it rolls up *all* care items (plants and yard
                // zones flow in automatically), while the rows below show only whole-house upkeep.
                if !store.careItems.isEmpty {
                    HouseHealthBanner(health: CareItem.houseHealth(for: store.careItems))
                }
                if houseItems.isEmpty {
                    if store.careSuggestionsDismissed {
                        Text("Nothing under care yet — add the first thing you always forget.")
                            .foregroundStyle(Color.inkSoft)
                    } else {
                        careSuggestionsCard
                    }
                } else {
                    ForEach(houseItems) { item in
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

            Section("Plants") {
                if plantItems.isEmpty {
                    plantsEmptyCard
                } else {
                    ForEach(plantItems) { item in
                        PlantRow(
                            item: item,
                            members: store.members,
                            photo: item.photoPath.flatMap { store.carePhotos[$0] },
                            onEdit: { store.send(.editCareItemTapped(item)) },
                            onMarkDone: { taskID in
                                store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
                            }
                        )
                    }
                    addPlantButton
                }
            }
            .listRowBackground(Color.familySurface)

            Section("Yard & garden") {
                ForEach(zoneItems) { item in
                    // Zones are house-ish (sticker-slap mark-done, not the plant leaf-unfurl).
                    CareRow(
                        item: item,
                        members: store.members,
                        onEdit: { store.send(.editCareItemTapped(item)) },
                        onMarkDone: { taskID in
                            store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
                        }
                    )
                }
                // Seasonal starters persist (filtered to the not-yet-added ones) so several jobs can be
                // scheduled in one sitting — unlike the one-and-done House card. Dismissable.
                if !remainingYardStarters.isEmpty, !store.yardSuggestionsDismissed {
                    yardSuggestionsCard
                } else if zoneItems.isEmpty {
                    Text("Nothing in the yard yet — add a seasonal job.")
                        .foregroundStyle(Color.inkSoft)
                }
                addYardZoneButton
            }
            .listRowBackground(Color.familySurface)

            Section("Pets") {
                ForEach(petItems) { item in
                    PetRow(
                        item: item,
                        members: store.members,
                        photo: item.photoPath.flatMap { store.carePhotos[$0] },
                        expiringDoc: expiringDoc(for: item),
                        onEdit: { store.send(.editCareItemTapped(item)) },
                        onMarkDone: { taskID in
                            store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
                        }
                    )
                }
                // "The pack" persists (filtered to the not-yet-added dogs) so Fajita and Sprinkle can
                // both be added in one sitting. Dismissable.
                if !remainingPackStarters.isEmpty, !store.petSuggestionsDismissed {
                    packStarterCard
                } else if petItems.isEmpty {
                    Text("No pets yet — add one of the crew.")
                        .foregroundStyle(Color.inkSoft)
                }
                addPetButton
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
        .sheet(item: $store.scope(state: \.plantCapture, action: \.plantCapture)) { captureStore in
            PlantCaptureView(store: captureStore)
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

    // MARK: Plants (P9)

    private var plantsEmptyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen)
                Text("No plants yet")
                    .font(.headline).foregroundStyle(Color.ink)
            }
            Text("Add the monstera before it judges you.")
                .font(.caption).foregroundStyle(Color.inkSoft)
            addPlantButton
        }
        .padding(.vertical, 4)
    }

    private var addPlantButton: some View {
        Button {
            store.send(.addPlantTapped)
        } label: {
            Label("Add a plant", systemImage: "plus")
                .appearBounce()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("add-plant-button")
    }

    // MARK: Yard & garden (P9-C3)

    /// Starters not already on the board, matched by name — lets the card persist for multi-add.
    private var remainingYardStarters: [YardSuggestion] {
        let existing = Set(zoneItems.map(\.name))
        return YardSuggestion.starters.filter { !existing.contains($0.name) }
    }

    /// Seasonal-starters card mirroring the House-care one: each row one-tap-adds a yard zone anchored
    /// to the next occurrence of its month, repeating yearly. Persists (filtered) for multi-add;
    /// dismissable.
    private var yardSuggestionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seasonal jobs")
                .font(.headline).foregroundStyle(Color.ink)
            Text("Tap to schedule a landscaping job to its next window. Edit anytime.")
                .font(.caption).foregroundStyle(Color.inkSoft)
            ForEach(remainingYardStarters) { suggestion in
                Button {
                    store.send(.yardSuggestionTapped(suggestion))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.icon)
                            .foregroundStyle(Color.bacanGreen)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.name).foregroundStyle(Color.ink)
                            Text(yardSubtitle(suggestion))
                                .font(.caption2).foregroundStyle(Color.inkSoft)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.bacanGreen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("yard-suggestion-\(suggestion.id)")
            }
            Button("No thanks, I'll add my own") {
                store.send(.dismissYardSuggestions)
            }
            .font(.caption).foregroundStyle(Color.inkSoft)
            .accessibilityIdentifier("dismiss-yard-suggestions")
        }
        .padding(.vertical, 4)
    }

    /// "Next: Sep 15 · yearly" — the next-occurrence date the tap would anchor to.
    private func yardSubtitle(_ suggestion: YardSuggestion) -> String {
        let date = suggestion.nextAnchor().formatted(.dateTime.month(.abbreviated).day())
        return "Next: \(date) · yearly"
    }

    private var addYardZoneButton: some View {
        Button {
            store.send(.addYardZoneTapped)
        } label: {
            Label("Add a yard zone", systemImage: "plus")
                .appearBounce()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("add-yard-zone-button")
    }

    // MARK: Pets (P10)

    /// The soonest-expiring Family-Brain document linked to `pet` whose expiry is within 30 days (or
    /// past) — drives the terracotta countdown chip on the pet's row. `nil` when nothing's expiring.
    private func expiringDoc(for pet: CareItem) -> FamilyDomain.Document? {
        store.documents
            .filter { $0.linkedPetIds.contains(pet.id) }
            .compactMap { doc -> (FamilyDomain.Document, Date)? in
                guard let expiry = doc.expiryDate,
                      FamilyDomain.Document.dayCount(from: Date(), to: expiry) <= 30
                else { return nil }
                return (doc, expiry)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Dogs not already on the board, matched by name — lets "The pack" card persist for multi-add
    /// (adding Fajita still offers Sprinkle).
    private var remainingPackStarters: [PetSuggestion] {
        let existing = Set(petItems.map(\.name))
        return PetSuggestion.starters.filter { !existing.contains($0.name) }
    }

    /// The hyper-personal Pets starter — "The pack": one-tap adds for Fajita and Sprinkle (each
    /// pre-filled with the dog-care schedule), plus a blank pet and the dismiss line. Sky-accented,
    /// mirroring the yard seasonal-starters card.
    private var packStarterCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "pawprint.fill").foregroundStyle(Color.sky)
                Text("The pack")
                    .font(.headline).foregroundStyle(Color.ink)
            }
            Text("Add the dogs with their usual care schedule. Edit anytime.")
                .font(.caption).foregroundStyle(Color.inkSoft)
            ForEach(remainingPackStarters) { suggestion in
                Button {
                    store.send(.petSuggestionTapped(suggestion))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: suggestion.icon)
                            .foregroundStyle(Color.sky)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add \(suggestion.name)").foregroundStyle(Color.ink)
                            Text("Heartworm · flea & tick · grooming · nails")
                                .font(.caption2).foregroundStyle(Color.inkSoft)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.sky)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("pet-suggestion-\(suggestion.id)")
            }
            Button {
                store.send(.addPetTapped)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "pawprint")
                        .foregroundStyle(Color.inkSoft)
                        .frame(width: 24)
                    Text("Someone else…").foregroundStyle(Color.ink)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pet-suggestion-other")

            Button("No thanks, I'll add my own") {
                store.send(.dismissPetSuggestions)
            }
            .font(.caption).foregroundStyle(Color.inkSoft)
            .accessibilityIdentifier("dismiss-pet-suggestions")
        }
        .padding(.vertical, 4)
    }

    private var addPetButton: some View {
        Button {
            store.send(.addPetTapped)
        } label: {
            Label("Add a pet", systemImage: "plus")
                .appearBounce()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("add-pet-button")
    }
}

/// A single Plants row: circular photo thumbnail (or a leaf fallback), name, species, the soonest
/// task's due line (task-title-driven verb wording — "Water due today" / "Watered Jul 2 by …"), and
/// a water-drop mark-done affordance that plays the ``LeafUnfurl`` motion. Routes through the same
/// `markCareTaskDone` → ``CareCompletion``/`writeCareDone` path as House care.
private struct PlantRow: View {
    let item: CareItem
    let members: [HouseholdMember]
    /// Cached photo bytes for `item.photoPath`, if loaded. `nil` ⇒ leaf fallback.
    let photo: Data?
    let onEdit: () -> Void
    let onMarkDone: (_ taskID: String) -> Void

    @State private var unfurlOn = false

    private var soonest: CareTask? { item.soonestDueTask() }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(Color.ink)
                    speciesLine
                    dueLine
                }
            }
            .buttonStyle(.plain)

            Spacer()

            if let task = soonest {
                Button {
                    onMarkDone(task.id)
                    unfurlOn = true
                    Task { try? await Task.sleep(for: .milliseconds(800)); unfurlOn = false }
                } label: {
                    Image(systemName: "drop.fill")
                        .font(.title3)
                        .foregroundStyle(Color.bacanGreen)
                        .leafUnfurl(isOn: unfurlOn, color: .bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Water")
                .accessibilityIdentifier("plant-mark-done-\(item.id)")
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let photo, let image = UIImage(data: photo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Circle().fill(Color.bacanGreen.opacity(0.15))
                Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen)
            }
        }
    }

    /// Species / botanical line. A botanical (latin) name renders italic; a plain common name doesn't.
    /// The light level (P9.1), when set, trails ink-soft with a small sun glyph.
    @ViewBuilder
    private var speciesLine: some View {
        HStack(spacing: 5) {
            if let latin = item.speciesLatin, !latin.isEmpty {
                Text(latin).italic()
            } else if let species = item.species, !species.isEmpty {
                Text(species)
            }
            if let light = item.lightLevel, !light.isEmpty {
                if item.species?.isEmpty == false || item.speciesLatin?.isEmpty == false {
                    Text("·")
                }
                Label(light, systemImage: "sun.max")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .accessibilityIdentifier("plant-light-\(item.id)")
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.inkSoft)
    }

    /// Due line copy + color, task-title-driven. Domain gives the day math; the view owns voice.
    @ViewBuilder
    private var dueLine: some View {
        if let task = soonest {
            let days = task.daysUntilDue()
            if let d = days, d < 0 {
                Text("\(task.title) overdue by \(-d) day\(-d == 1 ? "" : "s")")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.terracotta)
            } else if days == 0 {
                Text("\(task.title) due today")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.bacanGreen)
            } else if let d = days {
                // Due in the future.
                if task.lastDoneAt != nil {
                    Text(doneText(task)).font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("\(task.title) due in \(d) day\(d == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
            } else {
                // Manual / seasonal (no interval).
                if task.lastDoneAt != nil {
                    Text(doneText(task)).font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("Mark it when you do it").font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
        } else {
            Text("No tasks yet — tap to add one").font(.caption).foregroundStyle(Color.inkSoft)
        }
    }

    /// "Watered Jul 2 by Migueluh" — the completed task's title picks the past-tense verb.
    private func doneText(_ task: CareTask) -> String {
        guard let last = task.lastDoneAt else { return "" }
        let date = last.formatted(.dateTime.month(.abbreviated).day())
        let verb = ActivityItem.careVerb(forTask: task.title).capitalizedFirst
        if let by = task.lastDoneBy, let name = members.first(where: { $0.id == by })?.name {
            return "\(verb) \(date) by \(name)"
        }
        return "\(verb) \(date)"
    }
}

private extension String {
    /// Uppercase just the first character ("watered" → "Watered"), leaving the rest untouched.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// A single Pets row (P10): circular photo thumbnail (or a sky-tinted pawprint fallback — sky reads
/// as the pets' accent), name, breed (ink-soft), the soonest task's due line, and a **sticker-slap**
/// mark-done affordance in sky. Routes through the same `markCareTaskDone` → ``CareCompletion``/
/// `writeCareDone` path as the rest of the care system.
private struct PetRow: View {
    let item: CareItem
    let members: [HouseholdMember]
    /// Cached photo bytes for `item.photoPath`, if loaded. `nil` ⇒ pawprint fallback.
    let photo: Data?
    /// The soonest linked Family-Brain doc expiring within 30 days (P10) — shows a terracotta chip.
    let expiringDoc: FamilyDomain.Document?
    let onEdit: () -> Void
    let onMarkDone: (_ taskID: String) -> Void

    @State private var slapOn = false

    private var soonest: CareTask? { item.soonestDueTask() }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(Circle())

            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundStyle(Color.ink)
                    if let breed = item.breed, !breed.isEmpty {
                        Text(breed).font(.caption2).foregroundStyle(Color.inkSoft)
                    }
                    dueLine
                    if let expiry = expiringDoc?.expiryDate {
                        DocumentDateChip(date: expiry, kind: .expiry)
                            .padding(.top, 2)
                    }
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
                        .foregroundStyle(Color.sky)
                        .stickerSlap(isOn: slapOn, color: .sky)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Mark done")
                .accessibilityIdentifier("pet-mark-done-\(item.id)")
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let photo, let image = UIImage(data: photo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Circle().fill(Color.sky.opacity(0.15))
                Image(systemName: "pawprint.fill").foregroundStyle(Color.sky)
            }
        }
    }

    /// Due line copy + color. Domain gives the day math; the view owns thresholds & voice. The done
    /// line uses the neutral "Done …" phrasing (a med/nail verb would read awkwardly here).
    @ViewBuilder
    private var dueLine: some View {
        if let task = soonest {
            let days = task.daysUntilDue()
            if days == nil {
                if task.lastDoneAt != nil {
                    Text(doneText(task)).font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("Mark it when you do it").font(.caption).foregroundStyle(Color.inkSoft)
                }
            } else if let d = days, d < 0 {
                Text("\(task.title) overdue by \(-d) day\(-d == 1 ? "" : "s")")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.terracotta)
            } else if days == 0 {
                Text("\(task.title) due today")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(Color.sky)
            } else if let d = days {
                if task.lastDoneAt != nil {
                    Text(doneText(task)).font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("\(task.title) due in \(d) day\(d == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
            }
        } else {
            Text("No tasks yet — tap to add one").font(.caption).foregroundStyle(Color.inkSoft)
        }
    }

    /// "Done Jul 2 by Migueluh" — neutral, matching the House-care convention.
    private func doneText(_ task: CareTask) -> String {
        guard let last = task.lastDoneAt else { return "" }
        let date = last.formatted(.dateTime.month(.abbreviated).day())
        if let by = task.lastDoneBy, let name = members.first(where: { $0.id == by })?.name {
            return "Done \(date) by \(name)"
        }
        return "Done \(date)"
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
                } else if let due = task.dueAt {
                    // Never done but anchored to a real date (a seasonal yard window) — name the date
                    // rather than a bare day count, which reads clearer for far-off seasonal jobs.
                    Text("Due \(due.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption).foregroundStyle(Color.inkSoft)
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

/// Compact whole-house-health banner at the top of the House-care section: terracotta "overdue",
/// marigold "due this week", or the bacanGreen caught-up state ("The house is happy.") with a subtle
/// seal bounce. The math is UI-free (``CareItem/houseHealth(for:now:within:)``); this owns the voice.
private struct HouseHealthBanner: View {
    let health: HouseHealth

    var body: some View {
        HStack(spacing: 12) {
            seal
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                if let detail { Text(detail).font(.caption).foregroundStyle(Color.inkSoft) }
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(accent.opacity(0.14))
        )
        .padding(.vertical, 2)
        .accessibilityIdentifier("house-health-banner")
    }

    private var isCaughtUp: Bool { if case .caughtUp = health { return true } else { return false } }

    /// The accent glyph — the caught-up seal gets a subtle appear bounce; the alert states don't.
    @ViewBuilder
    private var seal: some View {
        let icon = Image(systemName: symbol).font(.title3).foregroundStyle(accent)
        if isCaughtUp { icon.appearBounce() } else { icon }
    }

    private var accent: Color {
        switch health {
        case .overdue: .terracotta
        case .dueThisWeek: .marigold
        case .caughtUp: .bacanGreen
        }
    }

    private var symbol: String {
        switch health {
        case .overdue: "exclamationmark.triangle"
        case .dueThisWeek: "clock"
        case .caughtUp: "checkmark.seal.fill"
        }
    }

    private var title: String {
        switch health {
        case let .overdue(count, _, _):
            "\(count) thing\(count == 1 ? "" : "s") overdue"
        case let .dueThisWeek(count, _, _):
            "\(count) due this week"
        case .caughtUp:
            HouseHealth.happyLine
        }
    }

    private var detail: String? {
        switch health {
        case let .overdue(_, worstItem, daysOver):
            "\(worstItem) — \(daysOver) day\(daysOver == 1 ? "" : "s") over"
        case let .dueThisWeek(_, soonestItem, days):
            days == 0 ? "\(soonestItem) — due today" : "\(soonestItem) — due in \(days) day\(days == 1 ? "" : "s")"
        case .caughtUp:
            nil
        }
    }
}
