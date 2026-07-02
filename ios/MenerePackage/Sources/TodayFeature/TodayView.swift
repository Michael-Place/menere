import ComposableArchitecture
import DocsFeature
import FamilyDomain
import HueClient
import MenereUI
import SwiftUI

public struct TodayView: View {
    @Bindable var store: StoreOf<TodayReducer>
    private let cal = Calendar.current

    public init(store: StoreOf<TodayReducer>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                greeting

                briefingCard

                scheduleCard
                dinnerCard
                quickActions

                choresCard
                homeCareCard
                houseCard
                needsAttentionCard
                familyCard
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.task) }
        .refreshable { await store.send(.task).finish() }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greetingLine)
                .familyDisplay()
                .fixedSize(horizontal: false, vertical: true)
            Text(dateLine)
                .familyTitle(.subheadline)
                .foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greetingLine: String {
        let hour = cal.component(.hour, from: Date())
        let partOfDay: String
        switch hour {
        case 0..<12: partOfDay = "Good morning"
        case 12..<17: partOfDay = "Good afternoon"
        default: partOfDay = "Good evening"
        }
        if let name = store.firstName, !name.isEmpty {
            return "\(partOfDay), \(name)."
        }
        return "\(partOfDay)."
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return "\(f.string(from: Date())) at the Place house"
    }

    // MARK: AI daily briefing (P6-C3)

    /// Shown only while loading (skeleton) or when a briefing exists. On failure it's absent
    /// entirely — the dashboard never surfaces an AI error.
    @ViewBuilder
    private var briefingCard: some View {
        if store.briefingLoading || store.briefing != nil {
            card {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.subheadline)
                        .foregroundStyle(Color.inkSoft)
                    Text("Daily briefing")
                        .familyTitle(.headline)
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Button { store.send(.loadBriefing(force: true)) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                            .foregroundStyle(Color.bacanGreen)
                    }
                    .buttonStyle(.pressable)
                    .disabled(store.briefingLoading)
                }

                if store.briefingLoading {
                    briefingSkeleton
                } else if let briefing = store.briefing {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(briefing.summary)
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if !briefing.highlights.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(briefing.highlights, id: \.self) { line in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("•").foregroundStyle(Color.bacanGreen)
                                        Text(line)
                                            .foregroundStyle(Color.inkSoft)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var briefingSkeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.inkSoft.opacity(0.15))
                    .frame(height: 12)
                    .frame(maxWidth: i == 2 ? 180 : .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shimmering()
    }

    // MARK: Today's schedule

    private var scheduleCard: some View {
        let items = todaysOccurrences()
        return card {
            cardHeader("Today's schedule", symbol: "calendar")
            if items.isEmpty {
                emptyLine("Nothing on the books — a rare quiet day.")
            } else {
                VStack(spacing: 12) {
                    ForEach(items) { item in
                        scheduleRow(item)
                    }
                }
            }
        }
    }

    private func scheduleRow(_ item: TodayOccurrence) -> some View {
        HStack(spacing: 12) {
            Text(item.event.isAllDay ? "All day" : timeString(item.date))
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .frame(width: 64, alignment: .leading)
            Text(item.event.title)
                .foregroundStyle(Color.ink)
            Spacer()
            assigneeDots(item.event.assigneeIDs)
        }
    }

    private func assigneeDots(_ ids: [String]) -> some View {
        HStack(spacing: -6) {
            ForEach(store.members.filter { ids.contains($0.id) }) { member in
                let rgb = member.color.rgb
                Circle()
                    .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.familySurface, lineWidth: 1.5))
            }
        }
    }

    // MARK: Tonight's dinner

    private var dinnerCard: some View {
        card {
            cardHeader("Tonight's dinner", symbol: "fork.knife")
            if let entry = tonightsEntry, entry.isEatingOut {
                eatingOutContent(entry)
            } else if let title = tonightsDinnerTitle {
                Text(title)
                    .familyTitle()
                    .foregroundStyle(Color.ink)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    emptyLine("Nothing planned — cereal night?")
                    Button { store.send(.planDinnerTapped) } label: {
                        Label("Plan dinner", systemImage: "plus.circle.fill")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    /// The eating-out branch: title (+ reservation time), address, an async traffic-aware drive
    /// line, and — when a reservation is set — the idempotent add-to-calendar action.
    @ViewBuilder
    private func eatingOutContent(_ entry: MealPlanEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "storefront").foregroundStyle(Color.marigold)
                Text(outTonightLine(entry))
                    .familyTitle()
                    .foregroundStyle(Color.ink)
            }
            if entry.hasPlace, let address = entry.restaurantAddress, !address.isEmpty {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let driveLine = driveLine(entry) {
                Label {
                    Text(driveLine.text)
                } icon: {
                    Image(systemName: driveLine.timeToGo ? "figure.walk.departure" : "car.fill")
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(driveLine.timeToGo ? Color.terracotta : Color.bacanGreen)
                .accessibilityIdentifier("today-dinner-drive")
            }
            if entry.reservationAt != nil {
                dinnerCalendarAction
            }
        }
    }

    /// "Out tonight — Test Bistro" or "Out tonight — Test Bistro · 7:30".
    private func outTonightLine(_ entry: MealPlanEntry) -> String {
        let name = entry.restaurantName ?? ""
        if let time = entry.reservationTimeShort { return "Out tonight — \(name) · \(time)" }
        return "Out tonight — \(name)"
    }

    /// The drive line, or nil when there's no ETA yet / MKDirections failed. When a reservation is
    /// set (same-day), appends the leave-by time — computed as reservation − ETA − a 5-minute
    /// buffer. If that moment is already past, it flips to a terracotta "time to go".
    private func driveLine(_ entry: MealPlanEntry) -> (text: String, timeToGo: Bool)? {
        guard let mins = store.driveMinutes else { return nil }
        let base = "≈\(mins) min drive"
        guard let reservationAt = entry.reservationAt, cal.isDateInToday(reservationAt) else {
            return (base, false)
        }
        let leaveBy = reservationAt.addingTimeInterval(-Double(mins + 5) * 60)
        if leaveBy <= Date() {
            return ("\(base) — time to go", true)
        }
        return ("\(base) — leave by \(MealPlanEntry.shortTime(leaveBy))", false)
    }

    @ViewBuilder
    private var dinnerCalendarAction: some View {
        if store.dinnerOnCalendar {
            Label("On the calendar", systemImage: "checkmark.circle.fill")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .accessibilityIdentifier("today-dinner-on-calendar")
        } else {
            Button { store.send(.addDinnerToCalendarTapped) } label: {
                Label("Add to calendar", systemImage: "calendar.badge.plus")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.bacanGreen)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-dinner-add-to-calendar")
        }
    }

    private var tonightsEntry: MealPlanEntry? {
        store.mealPlan.first { cal.isDateInToday($0.date) }
    }

    private var tonightsDinnerTitle: String? {
        guard let entry = tonightsEntry, !entry.isEatingOut else { return nil }
        // Prefer the live recipe title (renames), falling back to the stored snapshot.
        return store.recipes.first { $0.id == entry.recipeID }?.title ?? entry.recipeTitle
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction("Add event", symbol: "calendar.badge.plus") { store.send(.quickAddEventTapped) }
            quickAction("Add to list", symbol: "checklist") { store.send(.quickAddListTapped) }
            quickAction("Plan dinner", symbol: "fork.knife") { store.send(.planDinnerTapped) }
        }
    }

    private func quickAction(_ title: String, symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.title3)
                Text(title)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.bacanGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.bacanGreen.opacity(0.12))
            )
        }
        .buttonStyle(.pressable)
    }

    // MARK: Chores today

    /// Incomplete chores that are overdue, due today, or undated — the family's actionable board for
    /// today. Sorted overdue → today → undated; within a bucket, by due date (undated by createdAt).
    /// Future-dated incomplete chores are excluded.
    private func choresToday() -> [Chore] {
        let startOfToday = cal.startOfDay(for: Date())
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        func bucket(_ c: Chore) -> Int? {
            guard let due = c.dueDate else { return 2 }   // undated
            if due < startOfToday { return 0 }            // overdue
            if due < endOfToday { return 1 }              // today
            return nil                                    // future — not on today's board
        }
        return store.chores
            .filter { !$0.isCompleted && bucket($0) != nil }
            .sorted { a, b in
                let ba = bucket(a)!, bb = bucket(b)!
                if ba != bb { return ba < bb }
                return (a.dueDate ?? a.createdAt) < (b.dueDate ?? b.createdAt)
            }
    }

    private var choresCard: some View {
        let all = choresToday()
        let shown = Array(all.prefix(6))
        let overflow = all.count - shown.count
        return card {
            cardHeader("Chores today", symbol: "checklist")
            if all.isEmpty {
                emptyLine("All clear — nothing on the board today.")
            } else {
                VStack(spacing: 12) {
                    ForEach(shown) { chore in choreRow(chore) }
                    if overflow > 0 {
                        Text("+\(overflow) more in Chores")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.inkSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func choreRow(_ chore: Chore) -> some View {
        let assignee = store.members.first { $0.id == chore.assigneeID }
        let color = assignee.map(memberColor) ?? .bacanGreen
        return HStack(spacing: 12) {
            Button { store.send(.toggleChore(chore)) } label: {
                Image(systemName: chore.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chore.isCompleted ? color : Color.inkSoft)
                    .stickerSlap(isOn: chore.isCompleted, color: color)
            }
            .buttonStyle(.pressable)

            VStack(alignment: .leading, spacing: 2) {
                Text(chore.title)
                    .foregroundStyle(Color.ink)
                if let assignee {
                    HStack(spacing: 5) {
                        Circle().fill(color).frame(width: 8, height: 8)
                        Text(firstName(assignee.name))
                            .font(.caption2).foregroundStyle(Color.inkSoft)
                    }
                }
            }
            Spacer()
            Text("\(chore.effectiveXP) XP")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
        }
    }

    // MARK: Home care (P8-C2)

    /// Care tasks due or overdue within a week, same math as the Home tab's House-care banner.
    private func careDue() -> [CareItem.CareDue] {
        CareItem.dueTasks(in: store.careItems)
    }

    /// Shown only when at least one care item exists. With due/overdue tasks → a card listing up to
    /// three (item name + due chip). All caught up → a single quiet "The house is happy." line, no
    /// card chrome. Nothing at all when there are zero care items.
    @ViewBuilder
    private var homeCareCard: some View {
        if !store.careItems.isEmpty {
            let due = careDue()
            if due.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.bacanGreen)
                    Text(HouseHealth.happyLine).foregroundStyle(Color.inkSoft)
                }
                .font(.system(.subheadline, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("today-house-happy")
            } else {
                card {
                    // Retitled "Care due" (P9): plants and house upkeep mix here. Each row already
                    // carries its own kind icon (leaf for plants, house glyphs for upkeep).
                    cardHeader("Care due", symbol: "checklist.checked")
                    VStack(spacing: 12) {
                        ForEach(Array(due.prefix(3))) { item in
                            TodayCareRow(due: item) {
                                store.send(.markCareTaskDone(itemID: item.item.id, taskID: item.task.id))
                            }
                        }
                    }
                }
                .accessibilityIdentifier("today-home-care")
            }
        }
    }

    // MARK: The house (Philips Hue, P12-C1)

    /// Present only when the bridge is reachable (`store.house != nil`). Not paired / not home →
    /// no card at all. This card NEVER surfaces an error — problems mean it hides or goes stale.
    @ViewBuilder
    private var houseCard: some View {
        if let house = store.house {
            card {
                houseCardHeader(house)
                if let temps = temperatureLine(house) {
                    Label {
                        Text(temps)
                    } icon: {
                        Image(systemName: "thermometer.medium")
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
                    .accessibilityIdentifier("today-house-temps")
                }
                Text(lightsSummary(house))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("today-house-lights")
                let presentations = ritualPresentations(house)
                if !presentations.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(presentations) { p in ritualButton(p) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .accessibilityIdentifier("today-house")
        }
    }

    /// The house-card header, now a tappable **"The house ›"** entry into the granular control
    /// surface (P12-C4). Pushes `HouseView` seeded with the already-loaded snapshot; the rest of the
    /// card (temps / lights summary / ritual buttons) is unchanged.
    private func houseCardHeader(_ house: HouseSnapshot) -> some View {
        NavigationLink {
            HouseView(
                config: house.config, members: store.members, bridges: house.bridges,
                lutronConfig: store.lutronConfig, sonosConfig: store.sonosConfig,
                nestConfig: store.nestConfig
            )
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
                Text("The house")
                    .familyTitle(.headline)
                    .foregroundStyle(Color.ink)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkSoft.opacity(0.6))
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("today-house-open")
    }

    /// "Famfis's room 72° · Oliver's room 71°" from the config's sensor labels, or nil when no
    /// labeled temperature sensor reported. Only labeled sensors show (unlabeled ones are noise).
    private func temperatureLine(_ house: HouseSnapshot) -> String? {
        // Labels are already merged per-bridge by `HouseSnapshot.labeledTemperatures`.
        let parts = house.labeledTemperatures.map { "\($0.label) \(Int($0.tempF.rounded()))°" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "4 lights on — Living room, Kitchen" (count of on-lights + up to two rooms with any light
    /// on), or "All lights off" when nothing's lit.
    private func lightsSummary(_ house: HouseSnapshot) -> String {
        let onCount = house.lights.filter(\.isOn).count
        guard onCount > 0 else { return "All lights off" }
        let rooms = house.rooms.filter(\.anyOn).map(\.name)
        let noun = onCount == 1 ? "light" : "lights"
        guard !rooms.isEmpty else { return "\(onCount) \(noun) on" }
        let shown = rooms.prefix(2).joined(separator: ", ")
        let more = rooms.count > 2 ? " +\(rooms.count - 2)" : ""
        return "\(onCount) \(noun) on — \(shown)\(more)"
    }

    /// Ordered, prominence-tagged ritual buttons — the pure `HueRitualLayout` rule (Bedtime
    /// evening-first/filled; Dinner filled when tonight is home-cooked).
    private func ritualPresentations(_ house: HouseSnapshot) -> [RitualPresentation] {
        // Only rituals whose OWN bridge is reachable can render (P12-C3).
        HueRitualLayout.ordered(
            rituals: house.recallableRituals,
            now: Date(),
            homeCookedDinner: isTonightHomeCooked
        )
    }

    /// A capsule ritual button. Prominent → filled bacanGreen; subdued → tinted. On success it
    /// morphs to a checkmark with a success haptic; while recalling it dims.
    private func ritualButton(_ p: RitualPresentation) -> some View {
        let succeeded = store.succeededRitual == p.ritual.key
        let recalling = store.recallingRitual == p.ritual.key
        return Button {
            store.send(.recallRitual(p.ritual))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: succeeded ? "checkmark" : ritualSymbol(p.ritual))
                    .contentTransition(.symbolEffect(.replace))
                Text(succeeded ? "Done" : p.ritual.label)
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(p.isProminent || succeeded ? Color.white : Color.bacanGreen)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(p.isProminent || succeeded ? Color.bacanGreen : Color.bacanGreen.opacity(0.14))
            )
            .opacity(recalling ? 0.6 : 1)
        }
        .buttonStyle(.pressable)
        .disabled(recalling)
        .successHaptic(succeeded)
        .accessibilityIdentifier("today-house-ritual-\(p.ritual.key)")
    }

    /// Bedtime → moon, Dinner → fork.knife; anything else falls back to a generic bulb.
    private func ritualSymbol(_ ritual: HueRitual) -> String {
        switch ritual.key {
        case HueRitualLayout.bedtimeKey: return "moon.fill"
        case HueRitualLayout.dinnerKey:  return "fork.knife"
        default:                          return "lightbulb"
        }
    }

    /// Tonight's meal plan is a home-cooked recipe (not eating out) — makes "Dinner's ready"
    /// prominent.
    private var isTonightHomeCooked: Bool {
        guard let entry = tonightsEntry, !entry.isEatingOut else { return false }
        return !entry.recipeID.isEmpty || !entry.recipeTitle.isEmpty
    }

    // MARK: Needs attention (Family Brain, P7-C3)

    /// Documents whose dueDate/expiryDate is past-due or within the next 30 days, soonest first.
    private func needsAttentionDocs() -> [FamilyDomain.Document] {
        let now = Date()
        return store.documents
            .filter { $0.needsAttention(now: now, within: 30) }
            .sorted { ($0.soonestActionableDate ?? .distantFuture) < ($1.soonestActionableDate ?? .distantFuture) }
    }

    /// Hidden entirely when nothing is due/expiring — the dashboard stays quiet when it can.
    @ViewBuilder
    private var needsAttentionCard: some View {
        let docs = needsAttentionDocs()
        if !docs.isEmpty {
            card {
                cardHeader("Needs attention", symbol: "exclamationmark.circle")
                VStack(spacing: 12) {
                    ForEach(Array(docs.prefix(3))) { doc in
                        HStack(spacing: 12) {
                            Text(doc.title)
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Spacer()
                            if let expiry = doc.expiryDate,
                               (doc.dueDate == nil || expiry <= doc.dueDate!) {
                                DocumentDateChip(date: expiry, kind: .expiry)
                            } else if let due = doc.dueDate {
                                DocumentDateChip(date: due, kind: .due)
                            }
                        }
                    }
                    Button { store.send(.delegate(.openLists)) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "brain")
                            Text("Family Brain")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("today-brain-link")
                }
            }
            .accessibilityIdentifier("today-needs-attention")
        }
    }

    // MARK: The family

    private var familyCard: some View {
        card {
            cardHeader("The family", symbol: "person.2.fill")
            if store.members.isEmpty {
                emptyLine("No one's here yet — invite the crew from Family.")
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(store.members) { member in memberTile(member) }
                }
            }
        }
    }

    private func memberTile(_ member: HouseholdMember) -> some View {
        let color = memberColor(member)
        return VStack(spacing: 6) {
            Image(systemName: member.avatarSystemName)
                .font(.title2)
                .foregroundStyle(color)
            Text(firstName(member.name))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("Lv \(level(for: member.id))")
                .font(.caption2)
                .foregroundStyle(Color.inkSoft)
            HStack(spacing: 12) {
                Label("\(eventsToday(for: member.id))", systemImage: "calendar")
                Label("\(openChores(for: member.id))", systemImage: "checklist")
            }
            .font(.caption2)
            .foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: Member helpers

    private func memberColor(_ member: HouseholdMember) -> Color {
        let rgb = member.color.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// View-local stats lookup — `store.stats` resolves to the state array, so the state's
    /// `stats(for:)` method isn't reachable through the store.
    private func level(for id: String) -> Int {
        (store.stats.first { $0.memberID == id } ?? MemberStats(id: id, memberID: id)).level
    }

    /// Today's events assigned to a member — reconciles with the schedule card above.
    private func eventsToday(for id: String) -> Int {
        todaysOccurrences().filter { $0.event.assigneeIDs.contains(id) }.count
    }

    /// Open chores on today's board assigned to a member — reconciles with the chores card above.
    private func openChores(for id: String) -> Int {
        choresToday().filter { $0.assigneeID == id }.count
    }

    private func firstName(_ full: String) -> String {
        full.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? full
    }

    // MARK: Card scaffolding

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.familySurface)
            )
    }

    private func cardHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(Color.inkSoft)
            Text(title)
                .familyTitle(.headline)
                .foregroundStyle(Color.ink)
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Color.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Occurrence helpers (reuse the Calendar agenda's client-side expansion)

    private func todaysOccurrences() -> [TodayOccurrence] {
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return store.events
            .flatMap { event in
                event.occurrences(from: start, to: end, calendar: cal)
                    .map { TodayOccurrence(event: event, date: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

/// A single Today "Home care" row: item name + a due chip (terracotta when overdue) and an inline
/// sticker-slap "Mark done" affordance. Its own `View` so the slap owns a `@State` trigger that
/// replays on each tap — same affordance as the Home tab's `CareRow`.
private struct TodayCareRow: View {
    let due: CareItem.CareDue
    let onMarkDone: () -> Void

    @State private var slapOn = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: due.item.iconSymbol)
                .font(.subheadline)
                .foregroundStyle(due.isOverdue ? Color.terracotta : Color.bacanGreen)
                .frame(width: 22)
            Text(due.item.name)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer()
            dueChip
            Button {
                onMarkDone()
                slapOn = true
                Task { try? await Task.sleep(for: .milliseconds(800)); slapOn = false }
            } label: {
                // Plants unfurl a droplet; house upkeep keeps the sticker-slap.
                let isPlant = due.item.kind == .plant
                Image(systemName: isPlant ? "drop.fill" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.bacanGreen)
                    .stickerSlap(isOn: isPlant ? false : slapOn, color: .bacanGreen)
                    .leafUnfurl(isOn: isPlant ? slapOn : false, color: .bacanGreen)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(due.item.kind == .plant ? "Water" : "Mark done")
            .accessibilityIdentifier("today-care-mark-done-\(due.item.id)")
        }
    }

    /// Overdue → terracotta "Nd over"; due today → bacanGreen "Due today"; upcoming → marigold "in Nd".
    private var dueChip: some View {
        let (text, color): (String, Color) = {
            if due.days < 0 {
                return ("\(-due.days)d over", .terracotta)
            } else if due.days == 0 {
                return ("Due today", .bacanGreen)
            } else {
                return ("in \(due.days)d", .marigold)
            }
        }()
        return Text(text)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
