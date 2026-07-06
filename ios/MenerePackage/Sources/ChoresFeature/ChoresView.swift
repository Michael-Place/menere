import AnalyticsClient
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
    /// P25 telemetry — the Home hub's card taps + detail opens (fire-and-forget). Logged from the
    /// view because the hub navigates view-side (`NavigationLink(value:)`), not through the reducer.
    @Dependency(\.analytics) private var analytics

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
                        .simultaneousGesture(TapGesture().onEnded {
                            analytics.log("home_card_tapped", ["card": "smart_home"])
                        })
                        smartHomePreview(config)
                    }
                    // Motion & Delight — Home's signature: care cards BLOOM in (scale 0.9→1 with a
                    // gentle overshoot), a plant-growth feel. Replays on every (re)selection.
                    .tabEntrance(.bloom, index: 0)
                }

                hubCard(.choresRewards, icon: "checklist", tint: .bacanGreen,
                        title: "Chores & rewards", status: choresStatus, id: "chores-rewards") { choresPreview }
                    .tabEntrance(.bloom, index: 1)
                hubCard(.houseCare, icon: "checkmark.seal.fill", tint: .marigold,
                        title: "House care", status: houseCareStatus, id: "house-care") { houseCarePreview }
                    .tabEntrance(.bloom, index: 2)
                hubCard(.plants, icon: "leaf.fill", tint: .bacanGreen,
                        title: "Plants", status: plantsStatus, id: "plants") { plantsPreview }
                    .tabEntrance(.bloom, index: 3)
                hubCard(.yard, icon: "tree.fill", tint: .marigold,
                        title: "Yard & garden", status: yardStatus, id: "yard") { yardPreview }
                    .tabEntrance(.bloom, index: 4)
                hubCard(.pets, icon: "pawprint.fill", tint: .sky,
                        title: "Pets", status: petsStatus, id: "pets") { petsPreview }
                    .tabEntrance(.bloom, index: 5)

                if !store.activity.isEmpty {
                    hubCard(.activity, icon: "clock.arrow.circlepath", tint: .sky,
                            title: "Recent activity", status: activityStatus, id: "activity") { activityPreview }
                        .tabEntrance(.bloom, index: 6)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Home")
        .navigationDestination(for: Destination.self) { destination in
            Group {
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
            // P25 telemetry: one clean touch logs both the card tap (overview screens) and the
            // per-element detail open (plant/pet/care). Plants is logged distinctly so we can compare
            // opens-vs-detail-taps — the exact friction signal we lacked.
            .onAppear { logDestinationOpened(destination) }
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
        .sheet(item: $store.scope(state: \.troubleshoot, action: \.troubleshoot)) { tsStore in
            PlantTroubleshootView(store: tsStore)
        }
        .alert("New reward", isPresented: $store.showAddReward) {
            TextField("What's the prize?", text: $store.newRewardTitle)
            TextField("XP cost", value: $store.newRewardCost, format: .number)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) { store.showAddReward = false }
            Button("Add") { store.send(.createReward) }
        }
    }

    /// P25 telemetry: map a pushed hub ``Destination`` to its analytics event. Overview screens →
    /// `home_card_tapped {card}`; per-element pages → `home_detail_opened {kind}`; the Plants overview
    /// gets its own `plants_opened` (opens-vs-detail-taps signal).
    private func logDestinationOpened(_ destination: Destination) {
        switch destination {
        case .choresRewards: analytics.log("home_card_tapped", ["card": "chores_rewards"])
        case .houseCare: analytics.log("home_card_tapped", ["card": "house_care"])
        case .plants: analytics.log("plants_opened")
        case .yard: analytics.log("home_card_tapped", ["card": "yard"])
        case .pets: analytics.log("home_card_tapped", ["card": "pets"])
        case .activity: analytics.log("home_card_tapped", ["card": "activity"])
        case .plantDetail: analytics.log("home_detail_opened", ["kind": "plant"])
        case .petDetail: analytics.log("home_detail_opened", ["kind": "pet"])
        case .careDetail: analytics.log("home_detail_opened", ["kind": "care"])
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
        if !items.isEmpty || store.homeProfile != nil {
            VStack(alignment: .leading, spacing: 8) {
                if !items.isEmpty {
                    HouseHealthBanner(health: CareItem.houseHealth(for: items))
                }
                // P29 — the maintenance readiness score, when a home profile has been set up.
                if let profile = store.homeProfile {
                    HomeHealthScoreCard(
                        score: HomeHealthCalculator.calculate(careItems: store.careItems, profile: profile)
                    )
                }
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
        return ScrapbookThumb(seed: plant.photoPath ?? plant.id, side: 44) {
            // H1: BacanImage reads through the cached pipeline + downsamples to the 44pt chip.
            BacanImage(path: plant.photoPath, targetSize: CGSize(width: 44, height: 44), contentMode: .fill) {
                ZStack {
                    Color.bacanGreen.opacity(0.15)
                    Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if thirsty {
                Image(systemName: "drop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(Circle().fill(Color.sky))
                    .offset(x: 1, y: -1)
            }
        }
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
        VStack(spacing: 4) {
            ScrapbookThumb(seed: pet.photoPath ?? pet.id, side: 44, clip: .roundedRect(8)) {
                // H1: BacanImage reads through the cached pipeline + downsamples to the 44pt chip.
                BacanImage(path: pet.photoPath, targetSize: CGSize(width: 44, height: 44), contentMode: .fill) {
                    ZStack {
                        Color.sky.opacity(0.15)
                        Image(systemName: "pawprint.fill").foregroundStyle(Color.sky)
                    }
                }
            }
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
        guard let uid = user?.id, let me = store.members.member(forUID: uid) else { return base }
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
        // Mirror the plants card: lead with the urgent (overdue) seasonal job, else the next dated one,
        // else the warm empty line. Same season math as the Yard overview header.
        let season = YardSeason.compute(store.careItems.filter { $0.kind == .zone })
        return season.hubStatus
    }

    private var petsStatus: String {
        let pets = store.careItems.filter { $0.kind == .pet }
        guard !pets.isEmpty else { return "No pets yet" }
        // The pack's health drives the line (P19-C2b): an expired/expiring vaccine reads loudest,
        // then an overdue care task, else the warm all-set line. Same math as the pack overview.
        return PackHealth.compute(pets: pets, documents: store.documents).hubStatus
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
            homeMaintenanceSection
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
        .sheet(item: $store.scope(state: \.homeMaintenance, action: \.homeMaintenance)) { maintStore in
            HomeMaintenanceView(store: maintStore)
        }
    }

    // MARK: Home maintenance (P29)

    /// The seeded-maintenance entry: a "Set up home maintenance" call-to-action before a profile
    /// exists, or the live readiness score + "Suggested maintenance" opener once it does.
    @ViewBuilder
    private var homeMaintenanceSection: some View {
        Section("Home maintenance") {
            if let profile = store.homeProfile {
                HomeHealthScoreCard(
                    score: HomeHealthCalculator.calculate(careItems: store.careItems, profile: profile)
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                Button {
                    store.send(.homeMaintenanceTapped)
                } label: {
                    Label("Suggested maintenance", systemImage: "wrench.and.screwdriver.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("suggested-maintenance-button")
                .listRowBackground(Color.familySurface)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Never wonder what the house needs. Set up a quick home profile and we'll suggest the seasonal upkeep that applies.")
                        .font(.subheadline).foregroundStyle(Color.inkSoft)
                    Button {
                        store.send(.homeMaintenanceTapped)
                    } label: {
                        Label("Set up home maintenance", systemImage: "house.and.flag.fill")
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.bacanGreen)
                    .accessibilityIdentifier("setup-home-maintenance-button")
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.familySurface)
            }
        }
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

// MARK: - Pack health (P19-C2b) — the pets OVERVIEW rollup

/// A pure, UI-free read of "the pack's health": per-pet, the soonest care task and the soonest linked
/// vet-doc expiry, with overdue/expired flagged. The pets OVERVIEW header and the Home-hub Pets card
/// share this so they always speak with one voice — an EXPIRED vaccine (Sprinkle's rabies) reads loud
/// in both places.
private struct PackHealth: Equatable {
    struct PetStatus: Equatable, Identifiable {
        let pet: CareItem
        /// Soonest care task and whole-days-until-due (`nil` days = manual / no cadence).
        let careTask: CareTask?
        let careDays: Int?
        /// Soonest-expiring linked vet document and whole-days-to-expiry (negative = already expired).
        let doc: FamilyDomain.Document?
        let docDays: Int?
        var id: String { pet.id }

        /// A care task due today or overdue.
        var careUrgent: Bool { (careDays ?? Int.max) <= 0 }
        /// A linked doc already past its expiry — the loudest signal.
        var docExpired: Bool { doc != nil && (docDays ?? Int.max) < 0 }
        /// A linked doc expiring within the 30-day attention window (expired included).
        var docSoon: Bool { doc != nil && (docDays ?? Int.max) <= 30 }
        /// This pet contributes to the "needs attention" rollup.
        var needsAttention: Bool { careUrgent || docSoon }
        /// Distinct signals this pet flags (a due task + an expiring doc = 2).
        var attentionCount: Int { (careUrgent ? 1 : 0) + (docSoon ? 1 : 0) }
    }

    let pets: [PetStatus]

    static func compute(
        pets: [CareItem], documents: [FamilyDomain.Document], now: Date = Date()
    ) -> PackHealth {
        let statuses = pets.map { pet -> PetStatus in
            let task = pet.soonestDueTask(now: now)
            let care = task?.daysUntilDue(now: now)
            let doc = documents
                .filter { $0.linkedPetIds.contains(pet.id) && $0.expiryDate != nil }
                .min { ($0.expiryDate ?? .distantFuture) < ($1.expiryDate ?? .distantFuture) }
            let docDays = doc?.expiryDate.map { FamilyDomain.Document.dayCount(from: now, to: $0) }
            return PetStatus(pet: pet, careTask: task, careDays: care, doc: doc, docDays: docDays)
        }
        return PackHealth(pets: statuses)
    }

    /// Total distinct attention signals across the pack.
    var attentionCount: Int { pets.reduce(0) { $0 + $1.attentionCount } }
    var allSet: Bool { attentionCount == 0 }

    /// Pets with an expired linked doc — the loudest signal (Sprinkle's rabies), most-overdue first.
    var expired: [PetStatus] { pets.filter(\.docExpired).sorted { ($0.docDays ?? 0) < ($1.docDays ?? 0) } }

    /// The single glanceable line for the Home-hub Pets card. Expired doc → overdue care → all set.
    var hubStatus: String {
        if let s = expired.first, let doc = s.doc {
            return "\(Self.firstName(s.pet.name))'s \(Self.docLabel(doc, petName: s.pet.name)) is overdue"
        }
        if let s = pets.filter(\.careUrgent).min(by: { ($0.careDays ?? 0) < ($1.careDays ?? 0) }),
           let task = s.careTask {
            let due = (s.careDays ?? 0) < 0 ? "overdue" : "due today"
            return "\(Self.firstName(s.pet.name))'s \(task.title.lowercased()) \(due)"
        }
        if let s = pets.filter(\.docSoon).min(by: { ($0.docDays ?? 0) < ($1.docDays ?? 0) }), let doc = s.doc {
            return "\(Self.firstName(s.pet.name))'s \(Self.docLabel(doc, petName: s.pet.name)) · \(s.docDays ?? 0)d"
        }
        return "The pack is all set"
    }

    /// A pet's first-name token, for compact copy.
    static func firstName(_ full: String) -> String {
        full.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? full
    }

    /// A short human label for a vet doc — strips the pet's name and generic paperwork nouns so
    /// "Sprinkle's Rabies Vaccination Certificate" reads as "rabies". Falls back to the full title.
    static func docLabel(_ doc: FamilyDomain.Document, petName: String) -> String {
        let petFirst = firstName(petName).lowercased()
        let drop: Set<String> = [
            "certificate", "certificates", "record", "records", "vaccine", "vaccines",
            "vaccination", "vaccinations", "shot", "shots", "doc", "document", "report", "proof", "the",
        ]
        let words = doc.title.split(whereSeparator: { $0.isWhitespace }).compactMap { raw -> String? in
            var w = String(raw).lowercased()
            if w.hasSuffix("'s") { w = String(w.dropLast(2)) }
            w = w.trimmingCharacters(in: .punctuationCharacters)
            if w.isEmpty || w == petFirst || drop.contains(w) { return nil }
            return w
        }
        let label = words.joined(separator: " ")
        return label.isEmpty ? doc.title : label
    }
}

// MARK: - Yard season (P19-C2b) — the yard OVERVIEW rollup

/// A pure read of the yard's seasonal calendar: OVERDUE seasonal jobs and the NEXT dated ones. The Yard
/// overview header and the Home-hub Yard card share it — lead with overdue, else what's coming.
private struct YardSeason: Equatable {
    struct Job: Equatable, Identifiable {
        let zone: CareItem
        let task: CareTask
        let due: Date
        let days: Int
        var id: String { "\(zone.id)/\(task.id)" }
        var name: String { zone.name }
    }
    /// Overdue seasonal jobs, most-overdue first.
    let overdue: [Job]
    /// Upcoming dated jobs, soonest first.
    let upcoming: [Job]

    static func compute(_ zones: [CareItem], now: Date = Date()) -> YardSeason {
        var jobs: [Job] = []
        for zone in zones {
            for task in zone.tasks {
                guard let due = task.dueAt, let days = task.daysUntilDue(now: now) else { continue }
                jobs.append(Job(zone: zone, task: task, due: due, days: days))
            }
        }
        let overdue = jobs.filter { $0.days < 0 && $0.task.isOverdue(now: now) }.sorted { $0.days < $1.days }
        let upcoming = jobs.filter { $0.days >= 0 }.sorted { $0.days < $1.days }
        return YardSeason(overdue: overdue, upcoming: upcoming)
    }

    var nothingScheduled: Bool { overdue.isEmpty && upcoming.isEmpty }

    /// The Home-hub Yard card line — overdue first, else the next dated job, else the empty line.
    var hubStatus: String {
        if let worst = overdue.first {
            return "\(worst.name) overdue by \(-worst.days)d"
        }
        if let next = upcoming.first {
            return "Next: \(next.name) · \(next.due.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "Nothing scheduled"
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
        .careUndoBanner(store)
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
                // P19-C4: a gentle pet-safety awareness line — the Place house has 3 pets roaming among
                // these plants, so a quiet "N are toxic to pets" nudge earns its place here.
                if toxicToPetsCount > 0 {
                    Label(
                        "\(toxicToPetsCount) toxic to pets — tap a plant to see which",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.terracotta)
                    .padding(.top, 2)
                    .accessibilityIdentifier("plants-toxic-count")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        .accessibilityIdentifier("plants-triage-header")
    }

    /// How many plants carry a profile flagged toxic to pets — powers the triage awareness line.
    private var toxicToPetsCount: Int {
        plantItems.filter { $0.speciesProfile?.petToxicity?.isToxicToPets == true }.count
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
    @Dependency(\.analytics) private var analytics
    /// P26-IMG-C2 — flips the hero between the framed photo and the die-cut sticker (when one exists).
    @State private var showSticker = false
    /// P31 — expands the "Recommended schedule" section (collapsed by default so the page stays calm).
    @State private var scheduleExpanded = false

    /// Re-derived live from the store so mark-done reflects immediately (and the page empties
    /// gracefully if the plant is deleted from the edit form).
    private var plant: CareItem? { store.careItems.first { $0.id == plantID } }

    var body: some View {
        ScrollView {
            if let plant {
                VStack(spacing: 16) {
                    hero(plant)
                    if let toxicity = plant.speciesProfile?.petToxicity {
                        petSafetyBanner(toxicity)
                    }
                    overviewCard(plant)
                    if let profile = plant.speciesProfile, profile.hasContent {
                        goodToKnowCard(profile)
                    }
                    careTasksCard(plant)
                    recommendedScheduleCard(plant)
                    detailsCard(plant)
                    troubleshootSeam(plant)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .task {
                    if plant.speciesProfile != nil { analytics.log("plant_profile_viewed") }
                }
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
            if showSticker, let sticker = stickerImage(plant) {
                ScrapbookSticker(
                    image: sticker, seed: (plant.stickerPath ?? plant.id) + "-sticker",
                    caption: plant.name, date: plant.createdAt, aspect: 1.3
                ) {
                    Image(systemName: "leaf.fill").font(.system(size: 60))
                        .foregroundStyle(Color.bacanGreen.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrapbookPhoto(
                    image: plantImage(plant),
                    seed: plant.photoPath ?? plant.id,
                    caption: plant.name,
                    date: plant.createdAt,
                    aspect: 1.3
                ) {
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
                .frame(maxWidth: .infinity)
            }
            if stickerImage(plant) != nil {
                stickerToggle
            }
            VStack(spacing: 6) {
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

    /// The little "Photo · Sticker" flip shown only when a die-cut sticker exists for this plant.
    private var stickerToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { sticker in
                Button {
                    withAnimation(.snappy) { showSticker = sticker }
                } label: {
                    Text(sticker ? "Sticker ✂️" : "Photo")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(showSticker == sticker ? .white : Color.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(showSticker == sticker ? Color.bacanGreen : Color.clear, in: Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("plant-hero-toggle-\(sticker ? "sticker" : "photo")")
            }
        }
        .padding(3)
        .background(Color.familySurface, in: Capsule())
    }

    /// Decoded cached photo for the plant, or `nil` (→ the scrapbook leaf fallback).
    private func plantImage(_ plant: CareItem) -> UIImage? {
        guard let path = plant.photoPath, let data = store.carePhotos[path] else { return nil }
        return UIImage(data: data)
    }

    /// Decoded die-cut sticker cutout for the plant, or `nil` when it has none.
    private func stickerImage(_ plant: CareItem) -> UIImage? {
        guard let path = plant.stickerPath, let data = store.carePhotos[path] else { return nil }
        return UIImage(data: data)
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

    // MARK: Recommended schedule (P31) — the smart, per-species care plan

    /// The SMART per-species recommendation card (distinct from the manual "add care task" preset menu in
    /// the edit form). Mirrors the pet schedule card: an up-to-date signal + missing recommendations with
    /// ＋ (add due today) / ✓ (already do this / backdate), plus an "Already tracking" list. Reads
    /// ``PlantCareKB/schedule(for:)`` — misting only shows for humidity-lovers, fertilizing only in the
    /// growing season, watering at the plant's own cadence.
    @ViewBuilder
    private func recommendedScheduleCard(_ plant: CareItem) -> some View {
        let schedule = PlantCareKB.schedule(for: plant)
        let onScheduleCount = schedule.onScheduleCount()
        let missing = schedule.missing
        card {
            Button {
                withAnimation(.snappy) { scheduleExpanded.toggle() }
                if scheduleExpanded { store.send(.plantScheduleSetupOpened(plantID: plant.id)) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.bacanGreen.opacity(0.15))
                        Image(systemName: "sparkles").font(.subheadline).foregroundStyle(Color.bacanGreen)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recommended schedule").familyTitle(.headline)
                        Text(scheduleSignal(onScheduleCount, of: schedule.total))
                            .font(.caption).foregroundStyle(missing.isEmpty ? Color.bacanGreen : Color.inkSoft)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: scheduleExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("plant-schedule-toggle")

            if scheduleExpanded {
                Text("Tailored to this plant — misting only if it loves humidity, feeding only in the growing season.")
                    .font(.caption2).foregroundStyle(Color.inkSoft)

                ProgressView(value: Double(onScheduleCount), total: Double(max(schedule.total, 1)))
                    .tint(missing.isEmpty ? .bacanGreen : .bacanGreen)

                if missing.isEmpty {
                    Text("Every recommendation is set up — \(plant.name)'s got a full care plan. 🌱")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("Tap ＋ to add one to \(plant.name)'s care tasks, or ✓ if you already do it.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                    VStack(spacing: 10) {
                        ForEach(missing) { item in
                            scheduleSuggestionRow(item.template, plantID: plant.id)
                        }
                    }
                }

                if !schedule.present.isEmpty {
                    Divider()
                    Text("Already tracking")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.inkSoft)
                    VStack(spacing: 8) {
                        ForEach(schedule.present) { item in
                            scheduleHaveRow(item)
                        }
                    }
                }
            }
        }
    }

    /// "3 of 6 on schedule" / "All 6 on schedule 🎉" — the up-to-date signal.
    private func scheduleSignal(_ n: Int, of total: Int) -> String {
        if total > 0, n == total { return "All \(total) on schedule 🎉" }
        return "\(n) of \(total) on schedule"
    }

    /// A missing recommendation: glyph, title, cadence + note, and add / "already do this" buttons.
    private func scheduleSuggestionRow(_ template: PlantCareTemplate, plantID: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.bacanGreen.opacity(0.12))
                Image(systemName: template.symbol).font(.subheadline).foregroundStyle(Color.bacanGreen)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).foregroundStyle(Color.ink)
                Text(template.frequencyLabel).font(.caption2).foregroundStyle(Color.bacanGreen)
                Text(template.note).font(.caption2).foregroundStyle(Color.inkSoft).lineLimit(2)
            }
            Spacer(minLength: 4)
            // "I already do this" — materialize backdated so it lands caught-up.
            Button {
                store.send(.materializePlantCareTask(plantID: plantID, templateID: template.id, alreadyDone: true))
            } label: {
                Image(systemName: "checkmark.circle").font(.title3).foregroundStyle(Color.bacanGreen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(template.title) already done")
            .accessibilityIdentifier("plant-schedule-done-\(template.id)")
            // Add to the plant's care tasks as due.
            Button {
                store.send(.materializePlantCareTask(plantID: plantID, templateID: template.id, alreadyDone: false))
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.bacanGreen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(template.title)")
            .accessibilityIdentifier("plant-schedule-add-\(template.id)")
        }
    }

    /// An already-tracked recommendation row — a green check with the current due/overdue state.
    private func scheduleHaveRow(_ item: PlantScheduleItem) -> some View {
        let overdue = item.existingTask?.isOverdue() ?? false
        return HStack(spacing: 10) {
            Image(systemName: overdue ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(overdue ? Color.terracotta : Color.bacanGreen)
            Text(item.template.title).font(.caption).foregroundStyle(Color.ink)
            Spacer(minLength: 0)
            if overdue, let d = item.existingTask?.daysUntilDue() {
                Text("overdue \(-d)d").font(.caption2.weight(.semibold)).foregroundStyle(Color.terracotta)
            } else {
                Text(item.template.frequencyLabel).font(.caption2).foregroundStyle(Color.inkSoft)
            }
        }
    }

    // MARK: Details

    @ViewBuilder
    private func detailsCard(_ plant: CareItem) -> some View {
        let waterTask = plant.tasks.first { PlantCarePreset.matching($0.title) == .water }
        let hasAny = (plant.location?.isEmpty == false)
            || (plant.careContext?.isEmpty == false)
            || (plant.careNotes?.isEmpty == false)
            || (plant.familyNotes?.isEmpty == false)
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
                if let context = plant.careContext, !context.isEmpty {
                    detailRow("Its situation", context, symbol: "sparkles")
                }
                if let notes = plant.careNotes, !notes.isEmpty {
                    detailRow("Care notes", notes, symbol: "note.text")
                }
                if let familyNotes = plant.familyNotes, !familyNotes.isEmpty {
                    // Rich-Text C2 — render the family's own markdown note formatted.
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "heart.text.square")
                            .font(.subheadline).foregroundStyle(Color.bacanGreen)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Your notes")
                                .font(.caption).foregroundStyle(Color.inkSoft)
                            RichNoteText(markdown: familyNotes)
                        }
                    }
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

    // MARK: Troubleshoot (P19-C3) — context-aware AI "plant whisperer"

    /// P19-C3: the real "Troubleshoot this plant" entry point — opens the AI ``PlantTroubleshootView``
    /// sheet (Claude + optional problem photo + species + this plant's CONTEXT → diagnosis / fixes /
    /// optional one-tap watering-cadence change). The plant's `careContext` (edited in the form, shown in
    /// the Details card above) is passed straight through so the diagnosis reflects its situation.
    @ViewBuilder
    private func troubleshootSeam(_ plant: CareItem) -> some View {
        Button {
            store.send(.openTroubleshoot(plantID: plant.id))
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.sky.opacity(0.15))
                    Image(systemName: "stethoscope").font(.title3).foregroundStyle(Color.sky)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Troubleshoot this plant").familyTitle(.headline)
                    Text("Drooping? Spots? Brown tips? Ask Bacán.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color.inkSoft)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plant-troubleshoot-button")
    }

    // MARK: Pet safety (P19-C4) — the headline: is this plant safe around Fajita, Sprinkle & Fireball?

    /// The can't-miss banner near the top of the page: terracotta ⚠️ "Toxic to dogs & cats" (with who +
    /// the plain-language note), or bacanGreen ✓ "Pet-safe". This is the whole point of the chunk, so it
    /// gets a full-width, high-contrast treatment rather than a quiet chip.
    @ViewBuilder
    private func petSafetyBanner(_ toxicity: PetToxicity) -> some View {
        let toxic = toxicity.isToxicToPets
        let tint: Color = toxic ? .terracotta : .bacanGreen
        let symbol = toxic ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(petSafetyHeadline(toxicity))
                    .familyTitle(.headline)
                    .foregroundStyle(tint)
                if let note = toxicity.note, !note.isEmpty {
                    Text(note)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .accessibilityIdentifier("plant-pet-safety-banner")
    }

    /// "Toxic to dogs & cats" / "Toxic to dogs" / "Pet-safe" — names who's at risk, with severity when
    /// known ("Moderately toxic to cats").
    private func petSafetyHeadline(_ toxicity: PetToxicity) -> String {
        guard toxicity.isToxicToPets else { return "Pet-safe" }
        let who: String
        switch (toxicity.toxicToDogs, toxicity.toxicToCats) {
        case (true, true): who = "dogs & cats"
        case (true, false): who = "dogs"
        case (false, true): who = "cats"
        default: who = "pets"
        }
        if let sev = toxicity.severity?.trimmingCharacters(in: .whitespaces), !sev.isEmpty {
            let cap = sev.prefix(1).uppercased() + sev.dropFirst().lowercased()
            return "\(cap) — toxic to \(who)"
        }
        return "Toxic to \(who)"
    }

    // MARK: Good to know (P19-C4) — the rich species profile card

    /// The warm "Good to know" card: light, humidity, fertilizer, ideal temp and common problems for the
    /// species, from the AI profile. Only shown when the plant carries a profile with content.
    @ViewBuilder
    private func goodToKnowCard(_ profile: SpeciesProfile) -> some View {
        card {
            Label("Good to know", systemImage: "sparkles")
                .familyTitle(.headline)
            if let light = profile.lightNeed, !light.isEmpty {
                detailRow("Light", light, symbol: "sun.max.fill")
            }
            if let humidity = profile.humidity, !humidity.isEmpty {
                detailRow("Humidity", humidity, symbol: "humidity.fill")
            }
            if let fertilizer = profile.fertilizer, !fertilizer.isEmpty {
                detailRow("Fertilizer", fertilizer, symbol: "leaf.fill")
            }
            if let temp = profile.idealTemp, !temp.isEmpty {
                detailRow("Ideal temp", temp, symbol: "thermometer.medium")
            }
            if !profile.commonProblems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "stethoscope")
                            .font(.subheadline).foregroundStyle(Color.bacanGreen).frame(width: 22)
                        Text("Watch for").font(.caption).foregroundStyle(Color.inkSoft)
                        Spacer(minLength: 0)
                    }
                    ForEach(profile.commonProblems, id: \.self) { problem in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 5)).foregroundStyle(Color.inkSoft)
                                .padding(.top, 6).padding(.leading, 34)
                            Text(problem).foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
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
    /// P26-IMG-C2 — flips the hero between the framed photo and the die-cut sticker (when one exists).
    @State private var showSticker = false
    /// P31 — expands the "Set up care schedule" section (collapsed by default so the page stays calm).
    @State private var scheduleExpanded = false

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
                    scheduleSetupCard(pet)
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
            if showSticker, let sticker = stickerImage(pet) {
                ScrapbookSticker(
                    image: sticker, seed: (pet.stickerPath ?? pet.id) + "-sticker",
                    caption: pet.name, date: breedAgeLine(pet) == nil ? pet.createdAt : nil, aspect: 1.2
                ) {
                    Image(systemName: pet.iconSymbol.isEmpty ? "pawprint.fill" : pet.iconSymbol)
                        .font(.system(size: 60)).foregroundStyle(Color.sky.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrapbookPhoto(
                    image: petImage(pet),
                    seed: pet.photoPath ?? pet.id,
                    caption: pet.name,
                    date: breedAgeLine(pet) == nil ? pet.createdAt : nil,
                    aspect: 1.2
                ) {
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
                .frame(maxWidth: .infinity)
            }
            if stickerImage(pet) != nil {
                stickerToggle
            }
            VStack(spacing: 6) {
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

    /// The little "Photo · Sticker" flip shown only when a die-cut sticker exists for this pet.
    private var stickerToggle: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { sticker in
                Button {
                    withAnimation(.snappy) { showSticker = sticker }
                } label: {
                    Text(sticker ? "Sticker ✂️" : "Photo")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(showSticker == sticker ? .white : Color.ink)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(showSticker == sticker ? Color.sky : Color.clear, in: Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("pet-hero-toggle-\(sticker ? "sticker" : "photo")")
            }
        }
        .padding(3)
        .background(Color.familySurface, in: Capsule())
    }

    /// Decoded cached photo for the pet, or `nil` (→ the scrapbook pawprint/cat fallback).
    private func petImage(_ pet: CareItem) -> UIImage? {
        guard let path = pet.photoPath, let data = store.carePhotos[path] else { return nil }
        return UIImage(data: data)
    }

    /// Decoded die-cut sticker cutout for the pet, or `nil` when it has none.
    private func stickerImage(_ pet: CareItem) -> UIImage? {
        guard let path = pet.stickerPath, let data = store.carePhotos[path] else { return nil }
        return UIImage(data: data)
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

    // MARK: Recommended care schedule (P31)

    /// The species-appropriate recommended schedule (``PetCareKB``): an "N of M on schedule" signal,
    /// which recommendations the pet ALREADY has (checked off), and the missing ones — each tappable to
    /// materialize into the pet's care tasks (add as due, or "I already do this" to backdate). Warm,
    /// mirrors the plant/home-care setup UX.
    @ViewBuilder
    private func scheduleSetupCard(_ pet: CareItem) -> some View {
        let schedule = PetCareKB.schedule(for: pet)
        let onScheduleCount = schedule.onScheduleCount()
        let missing = schedule.missing
        careDetailCard {
            Button {
                withAnimation(.snappy) { scheduleExpanded.toggle() }
                if scheduleExpanded { store.send(.petScheduleSetupOpened(petID: pet.id)) }
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.sky.opacity(0.15))
                        Image(systemName: "checklist").font(.subheadline).foregroundStyle(Color.sky)
                    }
                    .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Care schedule").familyTitle(.headline)
                        Text(scheduleSignal(onScheduleCount, of: schedule.total, species: schedule.species))
                            .font(.caption).foregroundStyle(missing.isEmpty ? Color.bacanGreen : Color.inkSoft)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: scheduleExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("pet-schedule-toggle")

            if scheduleExpanded {
                // On-schedule progress bar (N of M).
                ProgressView(value: Double(onScheduleCount), total: Double(max(schedule.total, 1)))
                    .tint(missing.isEmpty ? .bacanGreen : .sky)

                if missing.isEmpty {
                    Text("Every \(schedule.species.displayName.lowercased()) recommendation is set up. \(pet.name)'s dialed in. 🐾")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                } else {
                    Text("Tap ＋ to add one to \(pet.name)'s care tasks, or ✓ if you already do it.")
                        .font(.caption).foregroundStyle(Color.inkSoft)
                    VStack(spacing: 10) {
                        ForEach(missing) { item in
                            scheduleSuggestionRow(item.template, petID: pet.id)
                        }
                    }
                }

                // Already-tracked recommendations, checked off for reassurance.
                if !schedule.present.isEmpty {
                    Divider()
                    Text("Already tracking")
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.inkSoft)
                    VStack(spacing: 8) {
                        ForEach(schedule.present) { item in
                            scheduleHaveRow(item)
                        }
                    }
                }
            }
        }
    }

    /// "5 of 9 on schedule" / "All 6 on schedule 🎉" — the up-to-date signal.
    private func scheduleSignal(_ n: Int, of total: Int, species: PetSpecies) -> String {
        if total > 0, n == total { return "All \(total) on schedule 🎉" }
        return "\(n) of \(total) on schedule"
    }

    /// A missing recommendation: glyph, title, cadence + note, and add / "already do this" buttons.
    private func scheduleSuggestionRow(_ template: PetCareTemplate, petID: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Color.sky.opacity(0.12))
                Image(systemName: petTaskGlyph(template.title)).font(.subheadline).foregroundStyle(Color.sky)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).foregroundStyle(Color.ink)
                Text(template.frequencyLabel).font(.caption2).foregroundStyle(Color.sky)
                Text(template.note).font(.caption2).foregroundStyle(Color.inkSoft).lineLimit(2)
            }
            Spacer(minLength: 4)
            // "I already do this" — materialize backdated so it lands caught-up.
            Button {
                store.send(.materializePetCareTask(petID: petID, templateID: template.id, alreadyDone: true))
            } label: {
                Image(systemName: "checkmark.circle").font(.title3).foregroundStyle(Color.bacanGreen)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(template.title) already done")
            .accessibilityIdentifier("pet-schedule-done-\(template.id)")
            // Add to the pet's care tasks as due.
            Button {
                store.send(.materializePetCareTask(petID: petID, templateID: template.id, alreadyDone: false))
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color.sky)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(template.title)")
            .accessibilityIdentifier("pet-schedule-add-\(template.id)")
        }
    }

    /// An already-tracked recommendation row — a green check with the current due/overdue state.
    private func scheduleHaveRow(_ item: PetScheduleItem) -> some View {
        let overdue = item.existingTask?.isOverdue() ?? false
        return HStack(spacing: 10) {
            Image(systemName: overdue ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(overdue ? Color.terracotta : Color.bacanGreen)
            Text(item.template.title).font(.caption).foregroundStyle(Color.ink)
            Spacer(minLength: 0)
            if overdue, let d = item.existingTask?.daysUntilDue() {
                Text("overdue \(-d)d").font(.caption2.weight(.semibold)).foregroundStyle(Color.terracotta)
            } else {
                Text(item.template.frequencyLabel).font(.caption2).foregroundStyle(Color.inkSoft)
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
    @Dependency(\.analytics) private var analytics

    private var zoneItems: [CareItem] { store.careItems.filter { $0.kind == .zone } }

    /// Starters not already on the board, matched by name — lets the card persist for multi-add.
    private var remainingYardStarters: [YardSuggestion] {
        let existing = Set(zoneItems.map(\.name))
        return YardSuggestion.starters.filter { !existing.contains($0.name) }
    }

    var body: some View {
        List {
            if !zoneItems.isEmpty {
                Section {
                    seasonHeader
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }

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
        .task { analytics.log("yard_overview_opened") }
    }

    // MARK: Seasonal OVERVIEW header (P19-C2b)

    /// A seasonal "what's coming" card mirroring the Plants triage header: the NEXT dated zone job,
    /// with any OVERDUE seasonal jobs flagged loud (terracotta), or a warm empty line when the yard
    /// calendar is bare. Only shown when there are zones (the starter card covers the true-empty case).
    private var seasonHeader: some View {
        let season = YardSeason.compute(zoneItems)
        let copy = seasonCopy(season)
        return HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(copy.tint.opacity(0.15))
                Image(systemName: copy.symbol).font(.title3).foregroundStyle(copy.tint)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(copy.headline)
                    .familyTitle(.headline).foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = copy.subhead {
                    Text(sub)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(copy.subheadTint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        .accessibilityIdentifier("yard-season-header")
    }

    /// Headline + subhead + icon/tint for the season card, derived from the ``YardSeason``.
    private func seasonCopy(
        _ s: YardSeason
    ) -> (headline: String, subhead: String?, subheadTint: Color, symbol: String, tint: Color) {
        func dateStr(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }
        if s.nothingScheduled {
            return ("Nothing on the yard calendar",
                    "Add a seasonal job for the season ahead.", .inkSoft, "tree.fill", .marigold)
        }
        if let worst = s.overdue.first {
            let n = s.overdue.count
            let headline = "\(n) seasonal job\(n == 1 ? "" : "s") overdue"
            var sub = "\(worst.name) overdue by \(-worst.days) day\(-worst.days == 1 ? "" : "s")"
            if let next = s.upcoming.first { sub += " · Next: \(next.name) · \(dateStr(next.due))" }
            return (headline, sub, .terracotta, "exclamationmark.triangle.fill", .terracotta)
        }
        // Upcoming only.
        let next = s.upcoming[0]
        let headline = "Next: \(next.name) · \(dateStr(next.due))"
        let sub = s.upcoming.count > 1 ? "Then \(s.upcoming[1].name) · \(dateStr(s.upcoming[1].due))" : nil
        return (headline, sub, .inkSoft, "calendar", .marigold)
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
    @Dependency(\.analytics) private var analytics

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
            if !petItems.isEmpty {
                Section {
                    packHeader
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
            }

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
        .careUndoBanner(store)
        .task { analytics.log("pets_overview_opened") }
    }

    // MARK: The pack — health OVERVIEW header (P19-C2b)

    /// A "The pack" summary card mirroring the Plants triage header: a rollup line ("2 things need
    /// attention across the pack" / "The pack is all set.") atop a compact per-pet status — each pet's
    /// soonest care task AND soonest linked vet-doc expiry, with an EXPIRED vaccine flagged loud in a
    /// filled terracotta pill (Sprinkle's rabies).
    private var packHeader: some View {
        let health = PackHealth.compute(pets: petItems, documents: store.documents)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().fill(rollupTint(health).opacity(0.15))
                    Image(systemName: rollupSymbol(health)).font(.title3).foregroundStyle(rollupTint(health))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The pack").familyTitle(.headline).foregroundStyle(Color.ink)
                    Text(rollupLine(health))
                        .font(.system(.subheadline, design: .rounded).weight(health.allSet ? .regular : .semibold))
                        .foregroundStyle(health.allSet ? Color.inkSoft : Color.terracotta)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                ForEach(health.pets) { petStatusRow($0) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        .accessibilityIdentifier("pets-pack-header")
    }

    private func rollupLine(_ h: PackHealth) -> String {
        if h.allSet { return "The pack is all set." }
        let n = h.attentionCount
        return "\(n) thing\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") attention across the pack."
    }

    private func rollupTint(_ h: PackHealth) -> Color { h.allSet ? .sky : .terracotta }
    private func rollupSymbol(_ h: PackHealth) -> String { h.allSet ? "pawprint.fill" : "exclamationmark.triangle.fill" }

    /// One pet's compact status: small avatar, name, its soonest care line, and its doc-expiry chip.
    private func petStatusRow(_ s: PackHealth.PetStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            packAvatar(s.pet)
            VStack(alignment: .leading, spacing: 4) {
                Text(s.pet.name)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                careLine(s)
                docChip(s)
                scheduleNudge(s.pet)
            }
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("pack-status-\(s.pet.id)")
    }

    private func packAvatar(_ pet: CareItem) -> some View {
        Group {
            if let path = pet.photoPath, let data = store.carePhotos[path], let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.sky.opacity(0.15)
                    Image(systemName: "pawprint.fill").font(.caption).foregroundStyle(Color.sky)
                }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
    }

    /// "Heartworm due today" / "Rabies overdue by 3d" / "All caught up" — the pet's soonest care.
    @ViewBuilder
    private func careLine(_ s: PackHealth.PetStatus) -> some View {
        if let task = s.careTask, let d = s.careDays {
            if d < 0 {
                packStatusLabel("\(task.title) overdue by \(-d)d", .terracotta, "cross.case.fill", bold: true)
            } else if d == 0 {
                packStatusLabel("\(task.title) due today", .sky, "cross.case.fill", bold: true)
            } else {
                packStatusLabel("\(task.title) · \(d)d", .inkSoft, "cross.case.fill", bold: false)
            }
        } else {
            packStatusLabel("All caught up", .inkSoft, "checkmark.circle", bold: false)
        }
    }

    /// P31 — a quiet "set up their schedule" nudge on the pack overview: how many recommended
    /// (``PetCareKB``) care tasks the pet is still missing. Points to the pet's detail to set them up.
    /// Hidden once the whole recommended schedule is tracked.
    @ViewBuilder
    private func scheduleNudge(_ pet: CareItem) -> some View {
        let missing = PetCareKB.schedule(for: pet).missing.count
        if missing > 0 {
            packStatusLabel("\(missing) to set up in care schedule", .sky, "checklist", bold: false)
                .accessibilityIdentifier("pack-schedule-nudge-\(pet.id)")
        }
    }

    private func packStatusLabel(_ text: String, _ tint: Color, _ symbol: String, bold: Bool) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(bold ? .semibold : .regular))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
    }

    /// The linked-doc expiry chip. EXPIRED ⇒ a LOUD filled-terracotta pill; expiring-soon ⇒ the soft
    /// terracotta chip; comfortably-future ⇒ nothing (the summary stays glanceable).
    @ViewBuilder
    private func docChip(_ s: PackHealth.PetStatus) -> some View {
        if let doc = s.doc, let d = s.docDays {
            let label = PackHealth.docLabel(doc, petName: s.pet.name).capitalizedFirst
            if d < 0 {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(label) EXPIRED")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(Color.terracotta))
                .accessibilityIdentifier("pack-doc-expired-\(s.pet.id)")
            } else if d <= 30 {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass")
                    Text("\(label) · \(d)d")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.terracotta)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(Color.terracotta.opacity(0.15)))
                .accessibilityIdentifier("pack-doc-soon-\(s.pet.id)")
            }
        }
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

/// The Home roster's one-tap "mark this task done" affordance (P28). A **labeled** capsule — not a
/// bare check/drop — so it's obvious what the tap does and which task it completes: the row's due-line
/// names the task, this pill names the action. Shown by its rows only when the soonest task is
/// actionable. Plays a leaf-unfurl (plant water) or sticker-slap (pets/other) on tap, then routes
/// through the shared `markCareTaskDone` → ``CareCompletion``/`writeCareDone` path — which arms the
/// ``CareUndoBanner`` so the tap is reversible.
private struct CareMarkDonePill: View {
    enum Motion { case leaf, slap }
    let title: String
    let icon: String
    let tint: Color
    let motion: Motion
    let accessibilityText: String
    let identifier: String
    let onTap: () -> Void

    @State private var animate = false

    var body: some View {
        Button {
            onTap()
            animate = true
            Task { try? await Task.sleep(for: .milliseconds(motion == .leaf ? 800 : 700)); animate = false }
        } label: {
            HStack(spacing: 5) {
                // `motion` is constant per instance, so this branch never thrashes view identity.
                if motion == .leaf {
                    Image(systemName: icon).leafUnfurl(isOn: animate, color: tint)
                } else {
                    Image(systemName: icon).stickerSlap(isOn: animate, color: tint)
                }
                Text(title)
            }
            .font(.system(.footnote, design: .rounded).weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier(identifier)
    }
}

/// The reversible "Marked {task} done · Undo" banner (P28) shown over the Home pets/plants rosters
/// after a one-tap completion. Reads ``ChoresReducer/State/careUndo`` (armed by `markCareTaskDone`);
/// Undo sends `undoCareTaskDone`, which restores the task's captured PRIOR done-stamp. Auto-dismisses
/// on its own timer (see the reducer); tapping the pill body dismisses without reversing.
private struct CareUndoBanner: ViewModifier {
    @Bindable var store: StoreOf<ChoresReducer>

    // A snackbar reads as an appearance-independent overlay (like system toasts), so it uses FIXED
    // dark chrome + bright accents rather than adaptive tokens — guaranteeing contrast in BOTH light
    // and dark. (An adaptive `.ink` fill flips to cream in dark and would wash out white text.)
    private let toastFill = Color(red: 0.165, green: 0.141, blue: 0.133)   // warm charcoal
    private let toastCheck = Color(red: 0.44, green: 0.78, blue: 0.60)     // bright mint
    private let toastUndo = Color(red: 0.93, green: 0.71, blue: 0.31)      // bright marigold

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let undo = store.careUndo {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(toastCheck)
                    Text("Marked \(undo.taskTitle) done")
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Undo") { store.send(.undoCareTaskDone, animation: .snappy) }
                        .font(.system(.subheadline, design: .rounded).weight(.bold))
                        .foregroundStyle(toastUndo)
                        .accessibilityIdentifier("care-undo")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .background(
                    Capsule(style: .continuous).fill(toastFill)
                        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 5)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .id(undo.nonce)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { store.send(.dismissCareUndo, animation: .snappy) }
            }
        }
        .animation(.snappy, value: store.careUndo)
    }
}

private extension View {
    /// Attach the reversible care-undo banner driven by `store.careUndo`. See ``CareUndoBanner``.
    func careUndoBanner(_ store: StoreOf<ChoresReducer>) -> some View {
        modifier(CareUndoBanner(store: store))
    }
}

/// A single Plants row: circular photo thumbnail (or a leaf fallback), name, species, the soonest
/// task's due line (task-title-driven verb wording — "Water due today" / "Watered Jul 2 by …"), and
/// a labeled mark-done pill (``CareMarkDonePill``) that plays the ``LeafUnfurl`` motion. Routes through
/// the same `markCareTaskDone` → ``CareCompletion``/`writeCareDone` path as House care. Tapping the row
/// (thumbnail/name area) pushes the plant DETAIL page (P19-C1) — the mark-done pill acts in place, so
/// it sits *outside* the navigating region.
private struct PlantRow: View {
    let item: CareItem
    let members: [HouseholdMember]
    /// Cached photo bytes for `item.photoPath`, if loaded. `nil` ⇒ leaf fallback.
    let photo: Data?
    let onMarkDone: (_ taskID: String) -> Void

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

            // Legibility (P28): show a LABELED pill — not a bare drop — and only when the soonest task
            // is actually actionable (due/overdue/manual). The label names the exact task the tap
            // completes (matched preset verb, e.g. "Water"/"Fertilize"), so it's clear on a glance.
            if let task = soonest, (task.daysUntilDue() ?? 0) <= 0 {
                let preset = PlantCarePreset.matching(task.title)
                CareMarkDonePill(
                    title: preset?.title ?? "Mark done",
                    icon: PlantCarePreset.symbol(forTitle: task.title),
                    tint: .bacanGreen,
                    motion: .leaf,
                    accessibilityText: "\(preset?.title ?? "Mark done") \(item.name)",
                    identifier: "plant-mark-done-\(item.id)",
                    onTap: { onMarkDone(task.id) }
                )
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

            // Legibility (P28): a LABELED "Mark done" pill instead of a bare check, shown only when the
            // soonest task is actually actionable (due/overdue/manual). The row's due-line names the
            // task ("Flea & tick due today"); this pill names the action, tying the two together.
            if let task = soonest, (task.daysUntilDue() ?? 0) <= 0 {
                CareMarkDonePill(
                    title: "Mark done",
                    icon: "checkmark.circle.fill",
                    tint: .sky,
                    motion: .slap,
                    accessibilityText: "Mark \(task.title) done for \(item.name)",
                    identifier: "pet-mark-done-\(item.id)",
                    onTap: { onMarkDone(task.id) }
                )
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
