import ComposableArchitecture
import DocsFeature
import FamilyDomain
import HouseFeature
import HueClient
import MenereUI
import SwiftUI
import UIKit
import UserDomain

/// The **Home** tab (P16) — a hub of glanceable OVERVIEW CARDS, each a leading tinted icon + title +
/// one-line live status + chevron, tapping into a rich detail screen. This is an IA restructure: the
/// detail screens hold the *exact* section content that used to stack in one long scroll, moved behind
/// TCA navigation and bound to the SAME ``ChoresReducer`` store (no duplicated reducers). The headline
/// fix is the **Smart home** card — the granular ``HouseView`` control screen (previously only reachable
/// from Today's "The house" card) now lives here too.
public struct ChoresView: View {
    @Bindable var store: StoreOf<ChoresReducer>
    /// The signed-in member — resolves "my" level for the Chores card summary.
    @Shared(.user) private var user

    public init(store: StoreOf<ChoresReducer>) {
        self.store = store
    }

    /// Hub destinations pushed onto the tab's `NavigationStack` (Smart home is a direct
    /// `NavigationLink` since it seeds ``HouseView`` from the loaded config).
    enum Destination: Hashable {
        case choresRewards, houseCare, plants, yard, pets, activity
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Smart home — HIDDEN unless a Hue config doc exists (same gate as Today's card). Its
                // header is the nav trigger (into the granular ``HouseView``); the preview's ritual chips
                // act in place, so this card can't be a single whole-card NavigationLink.
                if store.houseCard.isConfigured, let config = store.houseCard.config {
                    cardShell {
                        NavigationLink {
                            HouseView(
                                config: config, members: store.houseCard.members, bridges: store.houseCard.bridges,
                                lutronConfig: store.houseCard.lutronConfig, sonosConfig: store.houseCard.sonosConfig,
                                nestConfig: store.houseCard.nestConfig, hubspaceConfig: store.houseCard.hubspaceConfig,
                                merossConfig: store.houseCard.merossConfig, homekitConfig: store.houseCard.homekitConfig
                            )
                        } label: {
                            cardHeaderRow(icon: "house.fill", tint: .bacanGreen, title: "Smart home",
                                          status: store.houseCard.statusLine)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-card-smart-home")
                        smartHomePreview(config)
                    }
                }

                hubCard(.choresRewards, icon: "checklist", tint: .bacanGreen,
                        title: "Chores & rewards", status: choresStatus, id: "chores-rewards") { choresPreview }
                hubCard(.houseCare, icon: "checkmark.seal.fill", tint: .marigold,
                        title: "House care", status: houseCareStatus, id: "house-care") { houseCarePreview }
                hubCard(.plants, icon: "leaf.fill", tint: .bacanGreen,
                        title: "Plants", status: plantsStatus, id: "plants") { plantsPreview }
                hubCard(.yard, icon: "tree.fill", tint: .marigold,
                        title: "Yard & garden", status: yardStatus, id: "yard") { yardPreview }
                hubCard(.pets, icon: "pawprint.fill", tint: .sky,
                        title: "Pets", status: petsStatus, id: "pets") { petsPreview }

                if !store.activity.isEmpty {
                    hubCard(.activity, icon: "clock.arrow.circlepath", tint: .sky,
                            title: "Recent activity", status: activityStatus, id: "activity") { activityPreview }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Home")
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .choresRewards: ChoresRewardsDetailView(store: store)
            case .houseCare: HouseCareDetailView(store: store)
            case .plants: PlantsDetailView(store: store)
            case .yard: YardDetailView(store: store)
            case .pets: PetsDetailView(store: store)
            case .activity: ActivityDetailView(store: store)
            }
        }
        .overlay {
            // A level-up that arrives while the hub is visible still celebrates here.
            ConfettiBurst(color: confettiColor, trigger: store.confettiTrigger)
                .ignoresSafeArea()
        }
        .task { store.send(.task) }
        // Sheets + the reward alert live on the hub root so they present over whichever detail screen
        // triggered them — one wiring, unchanged behavior.
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

    // MARK: Card scaffold (header row navigates; preview body sits below)

    /// The rounded `familySurface` container every hub card wears.
    private func cardShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface)
            )
    }

    /// A value-nav hub card: a tappable header row (→ the detail screen) with a rich preview beneath.
    /// The header is the nav trigger (rather than the whole card) so interactive/scrolling preview
    /// content — plant strips, pet avatars — never fights a wrapping NavigationLink's gesture.
    private func hubCard<Preview: View>(
        _ destination: Destination, icon: String, tint: Color, title: String, status: String, id: String,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        cardShell {
            NavigationLink(value: destination) {
                cardHeaderRow(icon: icon, tint: tint, title: title, status: status)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-card-\(id)")
            preview()
        }
    }

    /// The header row shared by every card: leading tinted icon, title, one-line live status, chevron.
    private func cardHeaderRow(icon: String, tint: Color, title: String, status: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).familyTitle(.headline).foregroundStyle(Color.ink)
                Text(status)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.inkSoft.opacity(0.5))
        }
        .contentShape(Rectangle())
    }

    /// A member's brand color as a SwiftUI `Color`.
    private func color(for member: HouseholdMember) -> Color {
        let rgb = member.color.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    // MARK: - Smart home preview (room temps + inline ritual chips)

    /// Up to ~2 labeled room temperatures + tappable ritual chips. Both reuse the exact data Today's
    /// "The house" card renders (label-scoped sensors; ``HueRitualLayout`` ordering).
    @ViewBuilder
    private func smartHomePreview(_ config: HueConfig) -> some View {
        let temps = Array(houseTemps(config).prefix(2))
        let rituals = hubRituals(config)
        if !temps.isEmpty || !rituals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if !temps.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(temps.enumerated()), id: \.offset) { _, t in
                            tempChip(t.label, t.tempF)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !rituals.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(rituals) { ritualChip($0) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// (label, °F) for every labeled temperature sensor across reachable bridges — the same per-bridge
    /// label scoping as ``HouseSnapshot/labeledTemperatures``.
    private func houseTemps(_ config: HueConfig) -> [(label: String, tempF: Double)] {
        store.houseCard.bridges.flatMap { snap -> [(label: String, tempF: Double)] in
            let labels = config.sensorLabels(for: snap.bridge.bridgeId)
            return snap.temperatures.compactMap { t in labels[t.sensorId].map { ($0, t.tempF) } }
        }
        .sorted { $0.label < $1.label }
    }

    /// Ritual presentations for the chips — only rituals whose OWN bridge is reachable, ordered by the
    /// pure ``HueRitualLayout`` rule (the hub has no meal plan, so Dinner is never forced prominent).
    private func hubRituals(_ config: HueConfig) -> [RitualPresentation] {
        let reachable = Set(store.houseCard.bridges.map(\.bridge.bridgeId))
        let recallable = config.rituals.filter { reachable.contains($0.bridgeId) }
        return HueRitualLayout.ordered(rituals: recallable, now: Date(), homeCookedDinner: false)
    }

    private func tempChip(_ label: String, _ tempF: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "thermometer.medium").font(.caption2)
            Text("\(label) \(Int(tempF.rounded()))°")
        }
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(Color.inkSoft)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(Color.sky.opacity(0.12)))
    }

    /// A tappable ritual chip that fires the scene in place (dims while recalling). Prominent → filled.
    private func ritualChip(_ p: RitualPresentation) -> some View {
        let recalling = store.recallingRitual == p.ritual.key
        return Button {
            store.send(.recallRitual(p.ritual))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: ritualSymbol(p.ritual))
                Text(p.ritual.label)
            }
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .foregroundStyle(p.isProminent ? Color.white : Color.bacanGreen)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(p.isProminent ? Color.bacanGreen : Color.bacanGreen.opacity(0.14))
            )
            .opacity(recalling ? 0.6 : 1)
        }
        .buttonStyle(.pressable)
        .disabled(recalling)
        .accessibilityIdentifier("home-ritual-\(p.ritual.key)")
    }

    private func ritualSymbol(_ r: HueRitual) -> String {
        switch r.key {
        case HueRitualLayout.bedtimeKey: return "moon.fill"
        case HueRitualLayout.dinnerKey:  return "fork.knife"
        default:                          return "lightbulb"
        }
    }

    // MARK: - Chores & rewards preview (mini leaderboard)

    private struct MiniLeader: Identifiable, Equatable {
        let member: HouseholdMember
        let stats: MemberStats
        var id: String { member.id }
    }

    private var miniLeaderboard: [MiniLeader] {
        store.members
            .map { MiniLeader(member: $0, stats: memberStats(for: $0.id)) }
            .sorted { $0.stats.totalXP > $1.stats.totalXP }
    }

    @ViewBuilder
    private var choresPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !store.members.isEmpty {
                HStack(spacing: 14) {
                    ForEach(miniLeaderboard) { row in
                        VStack(spacing: 3) {
                            ZStack {
                                Circle().fill(color(for: row.member).opacity(0.18))
                                Image(systemName: row.member.avatarSystemName)
                                    .font(.subheadline)
                                    .foregroundStyle(color(for: row.member))
                            }
                            .frame(width: 38, height: 38)
                            Text("Lv \(row.stats.level)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.inkSoft)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(choresDueLine)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Color.inkSoft)
        }
    }

    /// "2 chores due today" (open chores due on/before today) or "All clear".
    private var choresDueLine: String {
        let cal = Calendar.current
        let now = Date()
        let dueToday = store.chores.filter { chore in
            guard !chore.isCompleted, let due = chore.dueDate else { return false }
            return cal.isDateInToday(due) || due < now
        }.count
        guard dueToday > 0 else { return "All clear" }
        return "\(dueToday) chore\(dueToday == 1 ? "" : "s") due today"
    }

    // MARK: - House care preview (health pill + soonest house/zone items)

    /// House-care is scoped to house + zone kinds — plants and pets have their own cards, so counting
    /// them here produced an alarming (and misleading) "39 due this week".
    private var houseCareItems: [CareItem] {
        store.careItems.filter { $0.kind == .house || $0.kind == .zone }
    }

    @ViewBuilder
    private var houseCarePreview: some View {
        let items = houseCareItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HouseHealthBanner(health: CareItem.houseHealth(for: items))
                ForEach(items.prefix(2)) { miniCareRow($0) }
            }
        }
    }

    /// A compact care row for the previews: small icon + name + a colored due chip.
    private func miniCareRow(_ item: CareItem) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.marigold.opacity(0.15))
                Image(systemName: item.iconSymbol).font(.caption).foregroundStyle(Color.marigold)
            }
            .frame(width: 28, height: 28)
            Text(item.name)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            careDueChip(item)
        }
    }

    @ViewBuilder
    private func careDueChip(_ item: CareItem) -> some View {
        let task = item.soonestDueTask()
        let days = task?.daysUntilDue()
        let (text, tint): (String, Color) = {
            guard let days else {
                if let due = task?.dueAt {
                    return ("Due \(due.formatted(.dateTime.month(.abbreviated).day()))", .inkSoft)
                }
                return ("Seasonal", .inkSoft)
            }
            if days < 0 { return ("\(-days)d over", .terracotta) }
            if days == 0 { return ("Today", .bacanGreen) }
            return ("\(days)d", .marigold)
        }()
        Text(text)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.15)))
    }

    // MARK: - Plants preview (horizontal photo strip, thirsty flagged)

    @ViewBuilder
    private var plantsPreview: some View {
        let plants = store.careItems.filter { $0.kind == .plant }
        if !plants.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(plants) { plantThumb($0) }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
    }

    private func plantThumb(_ plant: CareItem) -> some View {
        let thirsty = (plant.soonestDueTask()?.daysUntilDue() ?? 1) <= 0
        return ZStack(alignment: .topTrailing) {
            Group {
                if let path = plant.photoPath, let data = store.carePhotos[path], let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.bacanGreen.opacity(0.15)
                        Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if thirsty {
                Image(systemName: "drop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.sky))
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: 44, height: 44)
    }

    // MARK: - Yard preview (next seasonal zone task)

    @ViewBuilder
    private var yardPreview: some View {
        if let item = nextYardItem { miniCareRow(item) }
    }

    /// The soonest zone item anchored to a real date — the "next seasonal job".
    private var nextYardItem: CareItem? {
        store.careItems
            .filter { $0.kind == .zone && $0.soonestDueTask()?.dueAt != nil }
            .min { ($0.soonestDueTask()?.dueAt ?? .distantFuture) < ($1.soonestDueTask()?.dueAt ?? .distantFuture) }
    }

    // MARK: - Pets preview (photo avatars + soonest care chip)

    @ViewBuilder
    private var petsPreview: some View {
        let pets = store.careItems.filter { $0.kind == .pet }
        if !pets.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(pets) { petAvatar($0) }
                    Spacer(minLength: 0)
                }
                soonestPetChip
            }
        }
    }

    private func petAvatar(_ pet: CareItem) -> some View {
        VStack(spacing: 3) {
            Group {
                if let path = pet.photoPath, let data = store.carePhotos[path], let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.sky.opacity(0.15)
                        Image(systemName: "pawprint.fill").foregroundStyle(Color.sky)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            Text(firstName(pet.name))
                .font(.caption2)
                .foregroundStyle(Color.inkSoft)
                .lineLimit(1)
        }
    }

    /// The soonest pet care task within ~60 days, as a colored chip ("Sprinkle · vaccine 20d").
    @ViewBuilder
    private var soonestPetChip: some View {
        let soonest = store.careItems
            .filter { $0.kind == .pet }
            .compactMap { pet -> (label: String, days: Int)? in
                guard let task = pet.soonestDueTask(), let days = task.daysUntilDue(), days <= 60 else { return nil }
                return ("\(firstName(pet.name)) · \(task.title.lowercased())", days)
            }
            .min { $0.days < $1.days }
        if let soonest {
            let tint: Color = soonest.days < 0 ? .terracotta : (soonest.days == 0 ? .sky : .inkSoft)
            let text: String = soonest.days < 0
                ? "\(soonest.label) \(-soonest.days)d over"
                : (soonest.days == 0 ? "\(soonest.label) today" : "\(soonest.label) \(soonest.days)d")
            Text(text)
                .font(.system(.caption, design: .rounded).weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
        }
    }

    // MARK: - Recent activity preview (latest 2-3 lines)

    @ViewBuilder
    private var activityPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.activity.prefix(3)) { item in
                HStack(spacing: 8) {
                    Circle().fill(activityColor(item)).frame(width: 8, height: 8)
                    Text(item.text)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(item.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The activity dot color — the actor's member color, else the brand green.
    private func activityColor(_ item: ActivityItem) -> Color {
        guard let id = item.actorID, let m = store.members.first(where: { $0.id == id }) else { return .bacanGreen }
        return color(for: m)
    }

    // MARK: Overview-card status summaries (glanceable, one line each)

    private func memberStats(for id: String) -> MemberStats {
        store.stats.first { $0.memberID == id } ?? MemberStats(id: id, memberID: id)
    }

    private func firstName(_ full: String) -> String {
        full.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? full
    }

    private var choresStatus: String {
        let open = store.chores.filter { !$0.isCompleted }.count
        guard open > 0 else { return "All clear" }
        let base = "\(open) to do"
        guard let uid = user?.id, let me = store.members.first(where: { $0.id == uid }) else { return base }
        return "\(base) · \(firstName(me.name)) Lv \(memberStats(for: uid).level)"
    }

    private var houseCareStatus: String {
        let items = houseCareItems
        guard !items.isEmpty else { return "Nothing under care yet" }
        switch CareItem.houseHealth(for: items) {
        case .caughtUp: return HouseHealth.happyLine
        case let .overdue(count, _, _): return "\(count) thing\(count == 1 ? "" : "s") overdue"
        case let .dueThisWeek(count, _, _): return "\(count) due this week"
        }
    }

    private var plantsStatus: String {
        let plants = store.careItems.filter { $0.kind == .plant }
        guard !plants.isEmpty else { return "No plants yet" }
        let thirsty = plants.filter { ($0.soonestDueTask()?.daysUntilDue() ?? 1) <= 0 }.count
        let base = "\(plants.count) plant\(plants.count == 1 ? "" : "s")"
        return thirsty > 0 ? "\(base) · \(thirsty) thirsty" : base
    }

    private var yardStatus: String {
        let soonest = store.careItems.filter { $0.kind == .zone }
            .compactMap { zone -> (name: String, due: Date)? in
                guard let due = zone.soonestDueTask()?.dueAt else { return nil }
                return (zone.name, due)
            }
            .min { $0.due < $1.due }
        guard let soonest else { return "Nothing scheduled" }
        return "Next: \(soonest.name) · \(soonest.due.formatted(.dateTime.month(.abbreviated).day()))"
    }

    private var petsStatus: String {
        let pets = store.careItems.filter { $0.kind == .pet }
        guard !pets.isEmpty else { return "No pets yet" }
        let names = pets.map(\.name).joined(separator: ", ")
        let soonest = pets
            .compactMap { pet -> (label: String, days: Int)? in
                guard let task = pet.soonestDueTask(), let days = task.daysUntilDue(), days <= 30 else { return nil }
                return ("\(pet.name) \(task.title.lowercased())", days)
            }
            .min { $0.days < $1.days }
        guard let soonest else { return names }
        return "\(names) · \(soonest.label) · \(soonest.days)d"
    }

    private var activityStatus: String {
        store.activity.first?.text ?? "Nothing yet"
    }

    /// The confetti color for the most recent level-up (falls back to the brand green).
    private var confettiColor: Color {
        guard let mc = store.confettiColor else { return .bacanGreen }
        let rgb = mc.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Chores & rewards detail (Leaderboard · Chores · Rewards)

/// The Chores-tab's XP world, moved behind the "Chores & rewards" hub card. Same store, same actions —
/// chore complete (sticker-slap + server XP), rewards redemption, add chore/reward, and the level-up
/// ``ConfettiBurst`` all preserved exactly.
private struct ChoresRewardsDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    var body: some View {
        List {
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
            ConfettiBurst(color: confettiColor, trigger: store.confettiTrigger)
                .ignoresSafeArea()
        }
        .navigationTitle("Chores & rewards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("add-chore-button")
            }
        }
    }

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

// MARK: - House care detail

/// Whole-house upkeep, moved behind the "House care" hub card. The HouseHealth banner, care rows
/// (sticker-slap mark-done), starters, and add-a-care-item all unchanged.
private struct HouseCareDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    private var houseItems: [CareItem] { store.careItems.filter { $0.kind == .house } }

    var body: some View {
        List {
            Section("House care") {
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
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("House care")
        .navigationBarTitleDisplayMode(.inline)
    }

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

// MARK: - Plants detail

/// The plant roster, moved behind the "Plants" hub card. Rows play the ``LeafUnfurl`` water motion;
/// "Add a plant" still launches the capture wizard (presented from the hub root).
private struct PlantsDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    private var plantItems: [CareItem] { store.careItems.filter { $0.kind == .plant } }

    var body: some View {
        List {
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
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Plants")
        .navigationBarTitleDisplayMode(.inline)
    }

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
}

// MARK: - Yard & garden detail

/// Seasonal landscaping zones, moved behind the "Yard & garden" hub card. Seasonal starters (persisting
/// for multi-add) + add-a-zone unchanged.
private struct YardDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    private var zoneItems: [CareItem] { store.careItems.filter { $0.kind == .zone } }

    /// Starters not already on the board, matched by name — lets the card persist for multi-add.
    private var remainingYardStarters: [YardSuggestion] {
        let existing = Set(zoneItems.map(\.name))
        return YardSuggestion.starters.filter { !existing.contains($0.name) }
    }

    var body: some View {
        List {
            Section("Yard & garden") {
                ForEach(zoneItems) { item in
                    CareRow(
                        item: item,
                        members: store.members,
                        onEdit: { store.send(.editCareItemTapped(item)) },
                        onMarkDone: { taskID in
                            store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
                        }
                    )
                }
                if !remainingYardStarters.isEmpty, !store.yardSuggestionsDismissed {
                    yardSuggestionsCard
                } else if zoneItems.isEmpty {
                    Text("Nothing in the yard yet — add a seasonal job.")
                        .foregroundStyle(Color.inkSoft)
                }
                addYardZoneButton
            }
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Yard & garden")
        .navigationBarTitleDisplayMode(.inline)
    }

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
}

// MARK: - Pets detail

/// The pack, moved behind the "Pets" hub card. Pet rows (sticker-slap mark-done + terracotta doc-expiry
/// chip), "The pack" starters, and add-a-pet unchanged.
private struct PetsDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    private var petItems: [CareItem] { store.careItems.filter { $0.kind == .pet } }

    /// The soonest-expiring linked doc within 30 days (or past) for a pet — drives its terracotta chip.
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

    /// Dogs not already on the board, matched by name — lets "The pack" card persist for multi-add.
    private var remainingPackStarters: [PetSuggestion] {
        let existing = Set(petItems.map(\.name))
        return PetSuggestion.starters.filter { !existing.contains($0.name) }
    }

    var body: some View {
        List {
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
                if !remainingPackStarters.isEmpty, !store.petSuggestionsDismissed {
                    packStarterCard
                } else if petItems.isEmpty {
                    Text("No pets yet — add one of the crew.")
                        .foregroundStyle(Color.inkSoft)
                }
                addPetButton
            }
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Pets")
        .navigationBarTitleDisplayMode(.inline)
    }

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

// MARK: - Recent activity detail

/// The full activity feed, moved behind the "Recent activity" hub card.
private struct ActivityDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    var body: some View {
        List {
            Section("Recent activity") {
                ForEach(store.activity.prefix(30)) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage).foregroundStyle(Color.bacanGreen)
                        Text(item.text).font(.callout).foregroundStyle(Color.ink)
                    }
                }
            }
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Recent activity")
        .navigationBarTitleDisplayMode(.inline)
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
