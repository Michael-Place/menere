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
        /// P19-C1 — a single plant's rich DETAIL page (hero, overview, care-task list), pushed when a
        /// plant row is tapped. Carries the plant's id; the screen re-derives the live ``CareItem`` from
        /// the store so mark-done reflects immediately.
        case plantDetail(id: String)
        /// P19-C1b — a single pet's rich DETAIL page (hero photo, vet contact, overview with the
        /// soonest vaccine expiry, care tasks, the linked "Vet records" timeline), pushed on a pet-row
        /// tap. Re-derives the live ``CareItem`` from the store by id.
        case petDetail(id: String)
        /// P19-C1b — a house-care or yard-zone DETAIL page (name/location, overview, care tasks, notes),
        /// pushed on a house/zone row tap. Lighter than plant/pet: no photo/species/vet. Re-derives the
        /// live ``CareItem`` by id.
        case careDetail(id: String)
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
            case let .plantDetail(id): PlantDetailView(store: store, plantID: id)
            case let .petDetail(id): PetDetailView(store: store, petID: id)
            case let .careDetail(id): CareItemDetailView(store: store, itemID: id)
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
        // The hub card's status line IS the triage summary (P19-C2) — leads with the urgent water count
        // ("6 need water today"), else the soonest care, else "All 32 happy 🌿". Same math as the roster.
        return PlantTriage.compute(plants).hubStatus
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

// MARK: - Plants triage (P19-C2)

/// A pure, UI-free read of "what needs doing across ALL plants," grouped **by task type** — so the
/// Plants overview header and the Home-hub Plants card always agree. Water is the urgent bucket
/// (counted *due today / overdue*, `days <= 0`); every other care type (fertilize, prune, mist, …) is
/// counted *due within the week* (`days <= 7`, overdue included) since those cadences are longer.
/// "Happy" = plants whose soonest task is comfortably beyond a week (or has no cadence at all).
private struct PlantTriage: Equatable {
    /// Plants with a Water task due today or overdue.
    let waterNowCount: Int
    /// Non-water care types coming due this week, ordered by ``PlantCarePreset`` declaration (fertilize
    /// first), each with the number of distinct plants needing it.
    let otherSoon: [(preset: PlantCarePreset, count: Int)]
    /// Plants with nothing due inside the week.
    let happyCount: Int
    let totalCount: Int

    static func == (lhs: PlantTriage, rhs: PlantTriage) -> Bool {
        lhs.waterNowCount == rhs.waterNowCount && lhs.happyCount == rhs.happyCount
            && lhs.totalCount == rhs.totalCount
            && lhs.otherSoon.map(\.preset) == rhs.otherSoon.map(\.preset)
            && lhs.otherSoon.map(\.count) == rhs.otherSoon.map(\.count)
    }

    /// Nothing needs doing across the whole collection — the warm "all happy" state.
    var nothingDue: Bool { waterNowCount == 0 && otherSoon.isEmpty }

    static func compute(_ plants: [CareItem], now: Date = Date()) -> PlantTriage {
        var waterNow = 0
        var otherCounts: [PlantCarePreset: Int] = [:]
        for plant in plants {
            var needsWaterNow = false
            var soonPresets: Set<PlantCarePreset> = []
            for task in plant.tasks {
                guard let days = task.daysUntilDue(now: now) else { continue }
                let preset = PlantCarePreset.matching(task.title)
                if preset == .water {
                    if days <= 0 { needsWaterNow = true }
                } else if days <= 7, let preset {
                    soonPresets.insert(preset)
                }
            }
            if needsWaterNow { waterNow += 1 }
            for preset in soonPresets { otherCounts[preset, default: 0] += 1 }
        }
        let ordered = PlantCarePreset.allCases.compactMap { preset -> (PlantCarePreset, Int)? in
            guard preset != .water, let count = otherCounts[preset], count > 0 else { return nil }
            return (preset, count)
        }
        // Happy = soonest task is > 7 days out (or a manual/no-task plant → nil days).
        let happy = plants.filter {
            (($0.soonestDueTask(now: now)?.daysUntilDue(now: now)) ?? 8) > 7
        }.count
        return PlantTriage(
            waterNowCount: waterNow, otherSoon: ordered, happyCount: happy, totalCount: plants.count
        )
    }

    /// The verb phrase for a care type in triage copy — "need water", "to fertilize", … Count is
    /// prepended by the caller ("6 need water", "3 to fertilize").
    static func phrase(_ preset: PlantCarePreset) -> String {
        switch preset {
        case .water: "need water"
        case .fertilize: "to fertilize"
        case .repot: "to re-pot"
        case .prune: "to prune"
        case .rotate: "to rotate"
        case .mist: "to mist"
        case .cleanLeaves: "to clean"
        case .pestCheck: "to check for pests"
        }
    }

    /// The single glanceable status line for the Home-hub Plants card — leads with the urgent water
    /// count, else the soonest other care, else the warm all-happy line.
    var hubStatus: String {
        if nothingDue { return "All \(totalCount) happy 🌿" }
        if waterNowCount > 0 {
            return "\(waterNowCount) need\(waterNowCount == 1 ? "s" : "") water today"
        }
        if let first = otherSoon.first {
            return "\(first.count) \(PlantTriage.phrase(first.preset)) this week"
        }
        return "All \(totalCount) happy 🌿"
    }
}

// MARK: - Plants detail

/// The plant roster, moved behind the "Plants" hub card. P19-C2 turns the flat list into an OVERVIEW:
/// a TRIAGE HEADER (what needs doing across all 32 plants, by task type) atop plants **grouped by room**
/// (`location`), due-first within each room, with a per-room "Water this room" batch action. Rows keep
/// the ``LeafUnfurl`` water motion and still tap into the plant DETAIL page (P19-C1).
private struct PlantsDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>

    /// A transient "Watered N" confirmation per room key (keyed by the room's display name), shown in
    /// the section header for a beat after a batch water.
    @State private var wateredNote: [String: Int] = [:]

    private var plantItems: [CareItem] { store.careItems.filter { $0.kind == .plant } }

    /// The "no room yet" bucket's display name (rooms sort it last).
    private static let noRoom = "No room yet"

    /// Normalize a plant's `location` into a room key: trimmed non-empty, else `nil`.
    private func roomKey(_ location: String?) -> String? {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Plants grouped by room, sorted for display: rooms containing due plants float up (ties
    /// alphabetical), "No room yet" always last. Within a room, due-first (overdue → soonest → happy).
    private var roomGroups: [(name: String, key: String?, plants: [CareItem])] {
        let grouped = Dictionary(grouping: plantItems) { roomKey($0.location) }
        return grouped
            .map { key, plants -> (name: String, key: String?, plants: [CareItem]) in
                let sorted = plants.sorted {
                    let a = $0.soonestDueTask()?.daysUntilDue() ?? Int.max
                    let b = $1.soonestDueTask()?.daysUntilDue() ?? Int.max
                    return a == b ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : a < b
                }
                return (name: key ?? Self.noRoom, key: key, plants: sorted)
            }
            .sorted { lhs, rhs in
                if (rhs.key == nil) != (lhs.key == nil) { return rhs.key == nil }   // no-room last
                let lDue = dueWaterCount(in: lhs.plants) > 0
                let rDue = dueWaterCount(in: rhs.plants) > 0
                if lDue != rDue { return lDue }                                     // due rooms first
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Plants in a room whose Water task is due today/overdue — the batch-water eligible set.
    private func dueWaterCount(in plants: [CareItem]) -> Int {
        plants.filter { plant in
            plant.tasks.contains { PlantCarePreset.matching($0.title) == .water && $0.isDue() }
        }.count
    }

    var body: some View {
        List {
            if plantItems.isEmpty {
                Section("Plants") {
                    plantsEmptyCard
                }
                .listRowBackground(Color.familySurface)
            } else {
                Section {
                    triageHeader
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

                ForEach(roomGroups, id: \.name) { group in
                    Section {
                        ForEach(group.plants) { item in
                            PlantRow(
                                item: item,
                                members: store.members,
                                photo: item.photoPath.flatMap { store.carePhotos[$0] },
                                onMarkDone: { taskID in
                                    store.send(.markCareTaskDone(itemID: item.id, taskID: taskID))
                                }
                            )
                        }
                    } header: {
                        roomHeader(group)
                    }
                    .listRowBackground(Color.familySurface)
                }

                Section {
                    addPlantButton
                }
                .listRowBackground(Color.familySurface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Plants")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Triage header

    /// The overwhelm-killer: one warm card summarizing what needs doing across ALL plants, by task type.
    @ViewBuilder
    private var triageHeader: some View {
        let triage = PlantTriage.compute(plantItems)
        let copy = triageCopy(triage)
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(copy.tint.opacity(0.15))
                Image(systemName: copy.symbol).font(.title3).foregroundStyle(copy.tint)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.headline)
                    .familyTitle(.headline).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subhead = copy.subhead {
                    Text(subhead)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        .accessibilityIdentifier("plants-triage-header")
    }

    /// Headline + optional subhead + icon/tint for the triage card, derived from the ``PlantTriage``.
    private func triageCopy(_ t: PlantTriage) -> (headline: String, subhead: String?, symbol: String, tint: Color) {
        if t.nothingDue {
            return ("All your plants are happy 🌿", "Nothing needs doing today.", "leaf.fill", .bacanGreen)
        }
        // Build the ordered list of "N phrase" fragments (water first, then this-week care).
        var fragments: [String] = []
        if t.waterNowCount > 0 {
            fragments.append("\(t.waterNowCount) need\(t.waterNowCount == 1 ? "s" : "") water today")
        }
        for entry in t.otherSoon {
            fragments.append("\(entry.count) \(PlantTriage.phrase(entry.preset))")
        }
        let headline = fragments.first ?? "Some plants need care"
        var tail = Array(fragments.dropFirst())
        if t.happyCount > 0 {
            tail.append("everyone else is happy 🌿")
        }
        let symbol = t.waterNowCount > 0 ? "drop.fill" : "leaf.fill"
        let tint: Color = t.waterNowCount > 0 ? .sky : .bacanGreen
        return (headline, tail.isEmpty ? nil : tail.joined(separator: " · "), symbol, tint)
    }

    // MARK: Room section header + batch water

    @ViewBuilder
    private func roomHeader(_ group: (name: String, key: String?, plants: [CareItem])) -> some View {
        let dueWater = dueWaterCount(in: group.plants)
        HStack(spacing: 8) {
            Text(group.name)
            Spacer(minLength: 8)
            if let watered = wateredNote[group.name] {
                Label("Watered \(watered)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.bacanGreen)
                    .textCase(nil)
                    .transition(.opacity)
            } else if dueWater > 0 {
                Button {
                    store.send(.waterRoomDone(location: group.key))
                    withAnimation { wateredNote[group.name] = dueWater }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { wateredNote[group.name] = nil }
                    }
                } label: {
                    Label("Water this room", systemImage: "drop.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.sky)
                        .textCase(nil)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("water-room-\(group.key ?? "none")")
            }
        }
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

// MARK: - Plant detail (P19-C1)

/// A single plant's own little page: a full-width hero photo, a warm TOP OVERVIEW (health glance +
/// the soonest upcoming tasks), the FULL care-task list with inline ``LeafUnfurl`` mark-done, and the
/// plant's details. Bound to the SAME ``ChoresReducer`` store as the roster and re-derives the live
/// ``CareItem`` by id — so a mark-done here routes through ``CareCompletion``/`writeCareDone` (server-
/// consistent, logs activity with the right verb) and updates in place. The Edit button opens the
/// existing ``CareItemFormView`` (the edit path is unchanged; this screen is the new tap target).
private struct PlantDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>
    let plantID: String

    /// Re-derived live from the store so mark-done reflects immediately (and the page empties
    /// gracefully if the plant is deleted from the edit form).
    private var plant: CareItem? { store.careItems.first { $0.id == plantID } }

    var body: some View {
        ScrollView {
            if let plant {
                VStack(spacing: 16) {
                    hero(plant)
                    overviewCard(plant)
                    careTasksCard(plant)
                    detailsCard(plant)
                    troubleshootSeam(plant)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView("Plant not found", systemImage: "leaf")
                    .padding(.top, 60)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle(plant?.name ?? "Plant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let plant {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { store.send(.editCareItemTapped(plant)) }
                        .accessibilityIdentifier("plant-detail-edit")
                }
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ plant: CareItem) -> some View {
        VStack(spacing: 12) {
            heroPhoto(plant)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(spacing: 6) {
                Text(plant.name)
                    .familyTitle(.title2)
                if let species = heroSpecies(plant) {
                    Text(species).italic()
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                if let light = plant.lightLevel, !light.isEmpty {
                    lightChip(light)
                }
            }
        }
    }

    @ViewBuilder
    private func heroPhoto(_ plant: CareItem) -> some View {
        if let path = plant.photoPath, let data = store.carePhotos[path], let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            LinearGradient(
                colors: [Color.bacanGreen.opacity(0.35), Color.bacanGreen.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.bacanGreen.opacity(0.6))
            }
        }
    }

    /// The botanical name (rendered italic) when set, else the common name.
    private func heroSpecies(_ plant: CareItem) -> String? {
        if let latin = plant.speciesLatin, !latin.isEmpty { return latin }
        if let species = plant.species, !species.isEmpty { return species }
        return nil
    }

    private func lightChip(_ light: String) -> some View {
        Label(light, systemImage: "sun.max.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.marigold)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.marigold.opacity(0.18)))
    }

    // MARK: Overview (the glance)

    @ViewBuilder
    private func overviewCard(_ plant: CareItem) -> some View {
        let status = overviewStatus(plant)
        let upcoming = intervalTasksSoonestFirst(plant).prefix(2)
        card {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(status.tint.opacity(0.15))
                    Image(systemName: status.symbol).font(.title3).foregroundStyle(status.tint)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline).familyTitle(.headline)
                    Text(status.subhead)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 4)
            }
            if !upcoming.isEmpty {
                FlowChips(tasks: Array(upcoming), chip: dueChip)
            }
        }
    }

    /// The plant's one-line health glance: overdue (terracotta) → due-today (green) → all-caught-up.
    private func overviewStatus(_ plant: CareItem) -> (headline: String, subhead: String, symbol: String, tint: Color) {
        let overdue = plant.tasks.filter { $0.isOverdue() }
            .sorted { ($0.daysUntilDue() ?? 0) < ($1.daysUntilDue() ?? 0) }
        if let worst = overdue.first, let d = worst.daysUntilDue() {
            let n = -d
            return ("\(worst.title) is overdue", "By \(n) day\(n == 1 ? "" : "s") — give it some love.",
                    PlantCarePreset.symbol(forTitle: worst.title), .terracotta)
        }
        let dueToday = plant.tasks.filter { ($0.daysUntilDue() ?? 1) == 0 }
        if let today = dueToday.first {
            let extra = dueToday.count - 1
            let sub = extra > 0 ? "And \(extra) more due today." : "Right on schedule — mark it when it's done."
            return ("Needs \(today.title.lowercased()) today", sub,
                    PlantCarePreset.symbol(forTitle: today.title), .bacanGreen)
        }
        if let next = intervalTasksSoonestFirst(plant).first, let d = next.daysUntilDue() {
            return ("All caught up", "Next up: \(next.title.lowercased()) in \(d) day\(d == 1 ? "" : "s").",
                    "checkmark.seal.fill", .bacanGreen)
        }
        return ("All caught up", "This one's low-maintenance right now.", "checkmark.seal.fill", .bacanGreen)
    }

    /// Interval (auto-due) tasks, soonest-first (overdue first). Manual/seasonal tasks are excluded from
    /// the overview's "next up" glance since they never come due on their own.
    private func intervalTasksSoonestFirst(_ plant: CareItem) -> [CareTask] {
        plant.tasks
            .filter { $0.intervalDays != nil }
            .sorted { ($0.daysUntilDue() ?? Int.max) < ($1.daysUntilDue() ?? Int.max) }
    }

    private func dueChip(_ task: CareTask) -> some View {
        let overdue = task.isOverdue()
        let days = task.daysUntilDue()
        let tint: Color = overdue ? .terracotta : ((days ?? 1) <= 0 ? .bacanGreen : .inkSoft)
        return Label(dueChipText(task), systemImage: PlantCarePreset.symbol(forTitle: task.title))
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func dueChipText(_ task: CareTask) -> String {
        guard let d = task.daysUntilDue() else { return "\(task.title) · anytime" }
        if d < 0 { return "\(task.title) overdue \(-d)d" }
        if d == 0 { return "\(task.title) today" }
        return "\(task.title) in \(d) day\(d == 1 ? "" : "s")"
    }

    // MARK: Care tasks (every task, inline mark-done)

    @ViewBuilder
    private func careTasksCard(_ plant: CareItem) -> some View {
        card {
            Text("Care tasks").familyTitle(.headline)
            if plant.tasks.isEmpty {
                Text("No care tasks yet — tap Edit to add watering, fertilizing and more.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                VStack(spacing: 14) {
                    ForEach(plant.tasks) { task in
                        PlantTaskRow(
                            task: task,
                            members: store.members,
                            onMarkDone: {
                                store.send(.markCareTaskDone(itemID: plant.id, taskID: task.id))
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: Details

    @ViewBuilder
    private func detailsCard(_ plant: CareItem) -> some View {
        let waterTask = plant.tasks.first { PlantCarePreset.matching($0.title) == .water }
        let hasAny = (plant.location?.isEmpty == false)
            || (plant.careNotes?.isEmpty == false)
            || (waterTask?.lastDoneAt != nil)
        card {
            Text("Details").familyTitle(.headline)
            if !hasAny {
                Text("No details yet — add a location and care notes from Edit.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                if let location = plant.location, !location.isEmpty {
                    detailRow("Location", location, symbol: "mappin.and.ellipse")
                }
                if let notes = plant.careNotes, !notes.isEmpty {
                    detailRow("Care notes", notes, symbol: "note.text")
                }
                if let water = waterTask, let last = water.lastDoneAt {
                    detailRow("Last watered", lastDonePhrase(water, last: last), symbol: "drop.fill")
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline).foregroundStyle(Color.bacanGreen)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(Color.inkSoft)
                Text(value).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// "Jul 2 by Migueluh" — the completed-water date and who did it.
    private func lastDonePhrase(_ task: CareTask, last: Date) -> String {
        let date = last.formatted(.dateTime.month(.abbreviated).day())
        if let by = task.lastDoneBy, let name = store.members.first(where: { $0.id == by })?.name {
            return "\(date) by \(name)"
        }
        return date
    }

    // MARK: SEAM (P19-C3) — context-aware AI troubleshooting

    /// SEAM (P19-C3): context-aware adaptive care + AI troubleshooting lands here — a per-plant CONTEXT
    /// field (pot type / soil / indoor-outdoor / light exposure) that FEEDS care-interval adjustment,
    /// plus a "Troubleshoot / Ask about this plant" flow (Claude + optional problem photo + species +
    /// context → diagnosis / fix / optional interval change). Shipped now as a **disabled placeholder**
    /// so the entry point + layout are settled; C3 fills the action and the context editor.
    @ViewBuilder
    private func troubleshootSeam(_ plant: CareItem) -> some View {
        Button {} label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.sky.opacity(0.15))
                    Image(systemName: "stethoscope").font(.title3).foregroundStyle(Color.sky)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Troubleshoot this plant").familyTitle(.headline)
                    Text("Drooping? Spots? Pests? Ask — coming soon.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        }
        .buttonStyle(.plain)
        .disabled(true)
        .opacity(0.7)
        .accessibilityIdentifier("plant-troubleshoot-seam")
    }

    // MARK: Card scaffold

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
    }
}

/// One row in the plant DETAIL's care-task list: a kind glyph (derived from the task title via
/// ``PlantCarePreset/symbol(forTitle:)``), the task title, a due line ("Due today" / "Overdue by 2
/// days" / "Fertilized Jun 20 by Migueluh"), and an inline mark-done button that plays the shared
/// ``LeafUnfurl`` motion. Mark-done routes through the parent's `markCareTaskDone` →
/// ``CareCompletion``/`writeCareDone` path (server-consistent, logs activity with the right verb).
private struct PlantTaskRow: View {
    let task: CareTask
    let members: [HouseholdMember]
    let onMarkDone: () -> Void

    @State private var unfurlOn = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.bacanGreen.opacity(0.15))
                Image(systemName: PlantCarePreset.symbol(forTitle: task.title))
                    .font(.subheadline).foregroundStyle(Color.bacanGreen)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).foregroundStyle(Color.ink)
                dueLine
            }

            Spacer(minLength: 4)

            Button {
                onMarkDone()
                unfurlOn = true
                Task { try? await Task.sleep(for: .milliseconds(800)); unfurlOn = false }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.bacanGreen)
                    .leafUnfurl(isOn: unfurlOn, color: .bacanGreen)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Mark \(task.title) done")
            .accessibilityIdentifier("plant-task-done-\(task.id)")
        }
    }

    /// Due copy + color, mirroring the roster row's voice but scoped to this one task.
    @ViewBuilder
    private var dueLine: some View {
        let days = task.daysUntilDue()
        if let d = days, d < 0 {
            Text("Overdue by \(-d) day\(-d == 1 ? "" : "s")")
                .font(.caption).fontWeight(.semibold).foregroundStyle(Color.terracotta)
        } else if days == 0 {
            Text("Due today")
                .font(.caption).fontWeight(.semibold).foregroundStyle(Color.bacanGreen)
        } else if let d = days {
            if task.lastDoneAt != nil {
                Text(doneText).font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                Text("Due in \(d) day\(d == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            }
        } else {
            // Manual / seasonal (no cadence).
            if task.lastDoneAt != nil {
                Text(doneText).font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                Text("Mark it when you do it").font(.caption).foregroundStyle(Color.inkSoft)
            }
        }
    }

    /// "Fertilized Jun 20 by Migueluh" — the completed task's title picks the past-tense verb.
    private var doneText: String {
        guard let last = task.lastDoneAt else { return "" }
        let date = last.formatted(.dateTime.month(.abbreviated).day())
        let verb = ActivityItem.careVerb(forTask: task.title).capitalizedFirst
        if let by = task.lastDoneBy, let name = members.first(where: { $0.id == by })?.name {
            return "\(verb) \(date) by \(name)"
        }
        return "\(verb) \(date)"
    }
}

/// A tiny left-aligned wrapping row of due chips for the overview's "next up" glance. Two chips fit a
/// line on every device we target; this wraps defensively if a title runs long.
private struct FlowChips<Chip: View>: View {
    let tasks: [CareTask]
    let chip: (CareTask) -> Chip

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tasks) { task in chip(task) }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Shared care-detail scaffold (P19-C1b)

/// The rounded `familySurface` card that every care DETAIL screen (plant/pet/house/zone) wears — one
/// shared look so all four kinds read as one family of screens.
@ViewBuilder
private func careDetailCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12, content: content)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
}

/// A labeled detail line (glyph + caption label + value) used in the Details cards.
private func careDetailRow(_ label: String, _ value: String, symbol: String, tint: Color = .bacanGreen) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbol).font(.subheadline).foregroundStyle(tint).frame(width: 22)
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(Color.inkSoft)
            Text(value).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
    }
}

/// A compact due chip for the overview's "next up" glance (glyph + short due text, tinted by urgency).
private func careDueChip(_ task: CareTask, glyph: String, accent: Color) -> some View {
    let overdue = task.isOverdue()
    let days = task.daysUntilDue()
    let tint: Color = overdue ? .terracotta : ((days ?? 1) <= 0 ? accent : .inkSoft)
    return Label(careDueChipText(task), systemImage: glyph)
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(tint.opacity(0.12)))
}

private func careDueChipText(_ task: CareTask) -> String {
    guard let d = task.daysUntilDue() else { return "\(task.title) · anytime" }
    if d < 0 { return "\(task.title) overdue \(-d)d" }
    if d == 0 { return "\(task.title) today" }
    return "\(task.title) in \(d) day\(d == 1 ? "" : "s")"
}

/// One row in a pet / house / zone DETAIL's care-task list: a kind glyph, the task title, a due line,
/// and an inline **sticker-slap** mark-done (matching those rosters, vs the plant's LeafUnfurl). Routes
/// through the parent's `markCareTaskDone` → ``CareCompletion``/`writeCareDone` path (server-consistent,
/// logs activity). Seasonal (yearly) zone tasks name their due DATE rather than a bare day count.
private struct CareDetailTaskRow: View {
    let task: CareTask
    let members: [HouseholdMember]
    let glyph: String
    let tint: Color
    let onMarkDone: () -> Void

    @State private var slapOn = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: glyph).font(.subheadline).foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).foregroundStyle(Color.ink)
                dueLine
            }

            Spacer(minLength: 4)

            Button {
                onMarkDone()
                slapOn = true
                Task { try? await Task.sleep(for: .milliseconds(700)); slapOn = false }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .stickerSlap(isOn: slapOn, color: tint)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Mark \(task.title) done")
            .accessibilityIdentifier("care-detail-task-done-\(task.id)")
        }
    }

    @ViewBuilder
    private var dueLine: some View {
        let days = task.daysUntilDue()
        if days == nil {
            // Seasonal / manual (no cadence).
            if task.lastDoneAt != nil {
                Text(doneText).font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                Text("Mark it when you do it").font(.caption).foregroundStyle(Color.inkSoft)
            }
        } else if let d = days, d < 0 {
            Text("Overdue by \(-d) day\(-d == 1 ? "" : "s")")
                .font(.caption).fontWeight(.semibold).foregroundStyle(Color.terracotta)
        } else if days == 0 {
            Text("Due today").font(.caption).fontWeight(.semibold).foregroundStyle(tint)
        } else if let d = days, d <= 14 {
            Text("Due in \(d) day\(d == 1 ? "" : "s")").font(.caption).foregroundStyle(Color.inkSoft)
        } else if let d = days {
            // Far out — a seasonal yard window reads clearer as a date; a done task reassures with who.
            if task.lastDoneAt != nil {
                Text(doneText).font(.caption).foregroundStyle(Color.inkSoft)
            } else if let due = task.dueAt {
                Text("Due \(due.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                Text("Due in \(d) days").font(.caption).foregroundStyle(Color.inkSoft)
            }
        }
    }

    /// "Done Jul 2 by Migueluh" — neutral, matching the pet/house roster convention.
    private var doneText: String {
        guard let last = task.lastDoneAt else { return "" }
        let date = last.formatted(.dateTime.month(.abbreviated).day())
        if let by = task.lastDoneBy, let name = members.first(where: { $0.id == by })?.name {
            return "Done \(date) by \(name)"
        }
        return "Done \(date)"
    }
}

// MARK: - Pet detail (P19-C1b)

/// A single pet's own page: a hero photo (or sky-tinted pawprint/`cat.fill` fallback) with a
/// **breed · age** line and a tap-to-call vet chip, a TOP OVERVIEW (soonest care task + the soonest
/// vaccine/record expiry from linked docs), the FULL care-task list with inline sticker-slap mark-done,
/// the **Vet records** timeline (linked Family-Brain documents → real ``DocumentDetailView``), and the
/// details. Bound to the SAME ``ChoresReducer`` store and re-derives the live ``CareItem`` by id. The
/// Edit button opens the existing ``CareItemFormView`` (edit path unchanged).
private struct PetDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>
    let petID: String
    @Environment(\.openURL) private var openURL

    private var pet: CareItem? { store.careItems.first { $0.id == petID } }

    /// Linked Family-Brain documents for this pet, soonest-expiry (then due) first — undated last.
    private var linkedDocs: [FamilyDomain.Document] {
        store.documents
            .filter { $0.linkedPetIds.contains(petID) }
            .sorted { ($0.expiryDate ?? $0.dueDate ?? .distantFuture) < ($1.expiryDate ?? $1.dueDate ?? .distantFuture) }
    }

    /// The linked doc with the soonest expiry — drives the overview's vaccine-expiry line.
    private var soonestExpiringDoc: FamilyDomain.Document? {
        store.documents
            .filter { $0.linkedPetIds.contains(petID) && $0.expiryDate != nil }
            .min { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
    }

    var body: some View {
        ScrollView {
            if let pet {
                VStack(spacing: 16) {
                    hero(pet)
                    overviewCard(pet)
                    careTasksCard(pet)
                    vetRecordsCard
                    detailsCard(pet)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView("Pet not found", systemImage: "pawprint")
                    .padding(.top, 60)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle(pet?.name ?? "Pet")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let pet {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { store.send(.editCareItemTapped(pet)) }
                        .accessibilityIdentifier("pet-detail-edit")
                }
            }
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ pet: CareItem) -> some View {
        VStack(spacing: 12) {
            heroPhoto(pet)
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            VStack(spacing: 6) {
                Text(pet.name).familyTitle(.title2)
                if let sub = breedAgeLine(pet) {
                    Text(sub)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                if let vetName = pet.vetName, !vetName.isEmpty {
                    vetContactChip(name: vetName, phone: pet.vetPhone)
                }
            }
        }
    }

    @ViewBuilder
    private func heroPhoto(_ pet: CareItem) -> some View {
        if let path = pet.photoPath, let data = store.carePhotos[path], let img = UIImage(data: data) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            LinearGradient(
                colors: [Color.sky.opacity(0.35), Color.sky.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: pet.iconSymbol.isEmpty ? "pawprint.fill" : pet.iconSymbol)
                    .font(.system(size: 60))
                    .foregroundStyle(Color.sky.opacity(0.6))
            }
        }
    }

    /// "Dalmatian · 6 years" — breed and age, whichever are set (age computed from `birthday`).
    private func breedAgeLine(_ pet: CareItem) -> String? {
        var parts: [String] = []
        if let breed = pet.breed, !breed.isEmpty { parts.append(breed) }
        if let age = ageString(pet.birthday) { parts.append(age) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func ageString(_ birthday: Date?) -> String? {
        guard let birthday else { return nil }
        let comps = Calendar.current.dateComponents([.year, .month], from: birthday, to: Date())
        if let y = comps.year, y >= 1 { return "\(y) year\(y == 1 ? "" : "s")" }
        let m = max(comps.month ?? 0, 0)
        return "\(m) month\(m == 1 ? "" : "s")"
    }

    /// The vet chip — tapping calls `vetPhone` (a real `tel:` action). Disabled (still shows the name)
    /// when there's no number to dial.
    @ViewBuilder
    private func vetContactChip(name: String, phone: String?) -> some View {
        let digits = phone?.filter { $0.isNumber || $0 == "+" } ?? ""
        let callable = !digits.isEmpty
        Button {
            if callable, let url = URL(string: "tel:\(digits)") { openURL(url) }
        } label: {
            Label(name, systemImage: callable ? "phone.fill" : "cross.case.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.sky)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.sky.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(!callable)
        .accessibilityIdentifier("pet-vet-contact")
    }

    // MARK: Overview

    @ViewBuilder
    private func overviewCard(_ pet: CareItem) -> some View {
        let status = overviewStatus(pet)
        let upcoming = tasksSoonestFirst(pet).prefix(2)
        careDetailCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(status.tint.opacity(0.15))
                    Image(systemName: status.symbol).font(.title3).foregroundStyle(status.tint)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline).familyTitle(.headline)
                    Text(status.subhead)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 4)
            }
            if !upcoming.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(upcoming)) { task in
                        careDueChip(task, glyph: petTaskGlyph(task.title), accent: .sky)
                    }
                    Spacer(minLength: 0)
                }
            }
            if let doc = soonestExpiringDoc, let expiry = doc.expiryDate {
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: "syringe.fill")
                        .font(.subheadline).foregroundStyle(Color.sky).frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(doc.title).font(.caption).foregroundStyle(Color.inkSoft)
                        DocumentDateChip(date: expiry, kind: .expiry)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func overviewStatus(_ pet: CareItem) -> (headline: String, subhead: String, symbol: String, tint: Color) {
        let overdue = pet.tasks.filter { $0.isOverdue() }
            .sorted { ($0.daysUntilDue() ?? 0) < ($1.daysUntilDue() ?? 0) }
        if let worst = overdue.first, let d = worst.daysUntilDue() {
            let n = -d
            return ("\(worst.title) overdue", "By \(n) day\(n == 1 ? "" : "s") — take care of it.",
                    "exclamationmark.circle.fill", .terracotta)
        }
        let dueToday = pet.tasks.filter { ($0.daysUntilDue() ?? 1) == 0 }
        if let today = dueToday.first {
            let extra = dueToday.count - 1
            let sub = extra > 0 ? "And \(extra) more due today." : "Mark it when it's handled."
            return ("\(today.title) due today", sub, "pawprint.fill", .sky)
        }
        if let next = tasksSoonestFirst(pet).first, let d = next.daysUntilDue() {
            return ("All caught up", "Next up: \(next.title.lowercased()) in \(d) day\(d == 1 ? "" : "s").",
                    "checkmark.seal.fill", .bacanGreen)
        }
        return ("All caught up", "This one's easy right now.", "checkmark.seal.fill", .bacanGreen)
    }

    private func tasksSoonestFirst(_ item: CareItem) -> [CareTask] {
        item.tasks
            .filter { $0.intervalDays != nil }
            .sorted { ($0.daysUntilDue() ?? Int.max) < ($1.daysUntilDue() ?? Int.max) }
    }

    // MARK: Care tasks

    @ViewBuilder
    private func careTasksCard(_ pet: CareItem) -> some View {
        careDetailCard {
            Text("Care tasks").familyTitle(.headline)
            if pet.tasks.isEmpty {
                Text("No care tasks yet — tap Edit to add heartworm, grooming and more.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                VStack(spacing: 14) {
                    ForEach(pet.tasks) { task in
                        CareDetailTaskRow(
                            task: task,
                            members: store.members,
                            glyph: petTaskGlyph(task.title),
                            tint: .sky,
                            onMarkDone: {
                                store.send(.markCareTaskDone(itemID: pet.id, taskID: task.id))
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: Vet records (linked Family-Brain documents)

    @ViewBuilder
    private var vetRecordsCard: some View {
        careDetailCard {
            Text("Vet records").familyTitle(.headline)
            if linkedDocs.isEmpty {
                Text("No records yet — scan the vet paperwork and it'll file itself here.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
                    .accessibilityIdentifier("pet-detail-vet-records-empty")
            } else {
                VStack(spacing: 12) {
                    ForEach(linkedDocs) { doc in
                        NavigationLink {
                            DocumentDetailView(
                                store: Store(initialState: DocumentDetailReducer.State(doc: doc)) {
                                    DocumentDetailReducer()
                                }
                            )
                        } label: {
                            vetRecordRow(doc)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pet-detail-vet-record-\(doc.id)")
                    }
                }
            }
        }
    }

    private func vetRecordRow(_ doc: FamilyDomain.Document) -> some View {
        HStack(spacing: 10) {
            Image(systemName: doc.type.symbolName)
                .font(.subheadline).foregroundStyle(Color.sky).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(doc.title).foregroundStyle(Color.ink)
                if let expiry = doc.expiryDate {
                    DocumentDateChip(date: expiry, kind: .expiry)
                } else if let due = doc.dueDate {
                    DocumentDateChip(date: due, kind: .due)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.inkSoft)
        }
    }

    // MARK: Details

    @ViewBuilder
    private func detailsCard(_ pet: CareItem) -> some View {
        let hasAny = (pet.vetName?.isEmpty == false) || (pet.vetPhone?.isEmpty == false)
            || (pet.birthday != nil) || (pet.careNotes?.isEmpty == false)
        careDetailCard {
            Text("Details").familyTitle(.headline)
            if !hasAny {
                Text("No details yet — add a vet, birthday and notes from Edit.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                if let vet = pet.vetName, !vet.isEmpty {
                    careDetailRow("Vet", vet, symbol: "cross.case.fill", tint: .sky)
                }
                if let phone = pet.vetPhone, !phone.isEmpty {
                    careDetailRow("Vet phone", phone, symbol: "phone.fill", tint: .sky)
                }
                if let bday = pet.birthday {
                    careDetailRow("Birthday", bday.formatted(.dateTime.month(.abbreviated).day().year()),
                                  symbol: "gift.fill", tint: .sky)
                }
                if let notes = pet.careNotes, !notes.isEmpty {
                    careDetailRow("Notes", notes, symbol: "note.text", tint: .sky)
                }
            }
        }
    }
}

/// The kind glyph for a pet care task, derived from its title (heartworm → pills, flea/tick → ant,
/// grooming → comb, nails → scissors, litter → trash, vet → cross.case). Falls back to a paw.
private func petTaskGlyph(_ title: String) -> String {
    let t = title.lowercased()
    if t.contains("heartworm") || t.contains("pill") || t.contains("med") { return "pills.fill" }
    if t.contains("flea") || t.contains("tick") { return "ant.fill" }
    if t.contains("groom") || t.contains("bath") { return "comb.fill" }
    if t.contains("nail") { return "scissors" }
    if t.contains("litter") { return "trash.fill" }
    if t.contains("vet") || t.contains("checkup") || t.contains("check-up") { return "cross.case.fill" }
    if t.contains("walk") { return "figure.walk" }
    if t.contains("feed") { return "fork.knife" }
    return "pawprint.fill"
}

// MARK: - House / Zone care detail (P19-C1b)

/// A house-care or yard-zone item's page — lighter than plant/pet (no photo/species/vet): a header
/// (icon + name + location), a TOP OVERVIEW (soonest task status + due chips), the FULL care-task list
/// with inline sticker-slap mark-done, and notes. Yard-zone seasonal tasks name their due DATE. Bound
/// to the SAME ``ChoresReducer`` store, re-derives the live ``CareItem`` by id; Edit opens the form.
private struct CareItemDetailView: View {
    @Bindable var store: StoreOf<ChoresReducer>
    let itemID: String

    private var item: CareItem? { store.careItems.first { $0.id == itemID } }

    var body: some View {
        ScrollView {
            if let item {
                VStack(spacing: 16) {
                    header(item)
                    overviewCard(item)
                    careTasksCard(item)
                    if let notes = item.careNotes, !notes.isEmpty {
                        careDetailCard {
                            Text("Notes").familyTitle(.headline)
                            careDetailRow("Notes", notes, symbol: "note.text")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView("Not found", systemImage: "checkmark.seal")
                    .padding(.top, 60)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle(item?.name ?? "Care")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let item {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { store.send(.editCareItemTapped(item)) }
                        .accessibilityIdentifier("care-detail-edit")
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ item: CareItem) -> some View {
        careDetailCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.bacanGreen.opacity(0.15))
                    Image(systemName: item.iconSymbol).font(.title3).foregroundStyle(Color.bacanGreen)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).familyTitle(.title3)
                    if let location = item.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption).foregroundStyle(Color.inkSoft)
                    } else {
                        Text(item.kind == .zone ? "Yard & garden" : "House care")
                            .font(.caption).foregroundStyle(Color.inkSoft)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func overviewCard(_ item: CareItem) -> some View {
        let status = overviewStatus(item)
        let upcoming = tasksSoonestFirst(item).prefix(2)
        careDetailCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(status.tint.opacity(0.15))
                    Image(systemName: status.symbol).font(.title3).foregroundStyle(status.tint)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.headline).familyTitle(.headline)
                    Text(status.subhead)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 4)
            }
            if !upcoming.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(upcoming)) { task in
                        careDueChip(task, glyph: item.iconSymbol, accent: .bacanGreen)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func overviewStatus(_ item: CareItem) -> (headline: String, subhead: String, symbol: String, tint: Color) {
        let overdue = item.tasks.filter { $0.isOverdue() }
            .sorted { ($0.daysUntilDue() ?? 0) < ($1.daysUntilDue() ?? 0) }
        if let worst = overdue.first, let d = worst.daysUntilDue() {
            let n = -d
            return ("\(worst.title) overdue", "By \(n) day\(n == 1 ? "" : "s") — give it some attention.",
                    "exclamationmark.triangle.fill", .terracotta)
        }
        let dueToday = item.tasks.filter { ($0.daysUntilDue() ?? 1) == 0 }
        if let today = dueToday.first {
            let extra = dueToday.count - 1
            let sub = extra > 0 ? "And \(extra) more due today." : "Mark it when it's done."
            return ("\(today.title) due today", sub, "clock.fill", .marigold)
        }
        if let next = tasksSoonestFirst(item).first, let d = next.daysUntilDue() {
            return ("All caught up", "Next up: \(next.title.lowercased()) in \(d) day\(d == 1 ? "" : "s").",
                    "checkmark.seal.fill", .bacanGreen)
        }
        return ("All caught up", "Nothing needs doing right now.", "checkmark.seal.fill", .bacanGreen)
    }

    private func tasksSoonestFirst(_ item: CareItem) -> [CareTask] {
        item.tasks
            .filter { $0.intervalDays != nil }
            .sorted { ($0.daysUntilDue() ?? Int.max) < ($1.daysUntilDue() ?? Int.max) }
    }

    @ViewBuilder
    private func careTasksCard(_ item: CareItem) -> some View {
        careDetailCard {
            Text("Care tasks").familyTitle(.headline)
            if item.tasks.isEmpty {
                Text("No care tasks yet — tap Edit to add one.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            } else {
                VStack(spacing: 14) {
                    ForEach(item.tasks) { task in
                        CareDetailTaskRow(
                            task: task,
                            members: store.members,
                            glyph: item.iconSymbol,
                            tint: .bacanGreen,
                            onMarkDone: {
                                store.send(.markCareTaskDone(itemID: item.id, taskID: task.id))
                            }
                        )
                    }
                }
            }
        }
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
/// `markCareTaskDone` → ``CareCompletion``/`writeCareDone` path as House care. Tapping the row
/// (thumbnail/name area) now pushes the plant DETAIL page (P19-C1) — the mark-done drop still acts in
/// place, so it sits *outside* the navigating region.
private struct PlantRow: View {
    let item: CareItem
    let members: [HouseholdMember]
    /// Cached photo bytes for `item.photoPath`, if loaded. `nil` ⇒ leaf fallback.
    let photo: Data?
    let onMarkDone: (_ taskID: String) -> Void

    @State private var unfurlOn = false

    private var soonest: CareTask? { item.soonestDueTask() }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ChoresView.Destination.plantDetail(id: item.id)) {
                HStack(spacing: 12) {
                    thumbnail
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).foregroundStyle(Color.ink)
                        speciesLine
                        dueLine
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plant-row-\(item.id)")

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
    let onMarkDone: (_ taskID: String) -> Void

    @State private var slapOn = false

    private var soonest: CareTask? { item.soonestDueTask() }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ChoresView.Destination.petDetail(id: item.id)) {
                HStack(spacing: 12) {
                    thumbnail
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pet-row-\(item.id)")

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
    let onMarkDone: (_ taskID: String) -> Void

    @State private var slapOn = false

    private var soonest: CareTask? { item.soonestDueTask() }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ChoresView.Destination.careDetail(id: item.id)) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.bacanGreen.opacity(0.15))
                        Image(systemName: item.iconSymbol).foregroundStyle(Color.bacanGreen)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).foregroundStyle(Color.ink)
                        if let location = item.location, !location.isEmpty {
                            Text(location).font(.caption2).foregroundStyle(Color.inkSoft)
                        }
                        dueLine
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("care-row-\(item.id)")

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
