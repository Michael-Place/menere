import CalendarFeature
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import HouseFeature
import HueClient
import MenereUI
import SwiftUI

extension CelebrationStyle {
    /// Map a care item's kind + a task's title to the CelebrationKit flavor (D1). Mirrors ChoresFeature's
    /// mapping without a dependency on `PlantCarePreset` (a light substring match on the plant verb).
    static func forCare(kind: CareKind, taskTitle: String) -> CelebrationStyle {
        switch kind {
        case .plant:
            let t = taskTitle.lowercased()
            if t.contains("water") || t.contains("mist") { return .water }
            if t.contains("fertil") { return .fertilize }
            if t.contains("re-pot") || t.contains("repot") { return .repot }
            return .fertilize   // prune / rotate / clean / pest / custom → leafy plant-care
        case .pet: return .pet
        case .house, .zone: return .house
        }
    }

    /// Map a Family Radar care category to a flavor. The radar carries no task title, so plant care
    /// (dominantly overdue watering across the house's 32 plants) flavors to `.water`.
    static func forRadar(_ category: FamilyRadar.CareRadarItem.Category) -> CelebrationStyle {
        switch category {
        case .plant: .water
        case .pet: .pet
        case .house: .house
        }
    }
}

public struct TodayView: View {
    @Bindable var store: StoreOf<TodayReducer>
    private let cal = Calendar.current
    /// The single injected "now" that drives every time-aware decision (schedule split, dinner
    /// evening state, greeting). Reads the sim/device clock live; overridable in previews/tests.
    @Dependency(\.date.now) private var now

    public init(store: StoreOf<TodayReducer>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            // A calmer, intentional hierarchy (top→bottom): a quiet HEADER, the BRIEFING, one
            // consolidated "Needs you today" list, a compact "Today's plan", then quieter glances.
            // Sections still CASCADE in on every (re)selection; the glances POP in last.
            VStack(alignment: .leading, spacing: 26) {
                // (a) HEADER — greeting + date, with the photo nudge demoted to a slim inline prompt
                // that only appears when there's a fresh batch (or the one-time soft opt-in).
                VStack(alignment: .leading, spacing: 12) {
                    greeting
                    PhotoNudgeCard(store: store)
                }
                .tabEntrance(.cascade, index: 0)

                // (b) BRIEFING — the intentional "here's your day".
                briefingCard.tabEntrance(.cascade, index: 1)

                // (c) NEEDS YOU TODAY — Family Radar + overdue care + today's chores, merged into ONE
                // prioritized, scannable list (each row keeps its inline action). Empty = all caught up.
                needsYouCard.tabEntrance(.cascade, index: 2)

                // (d) TODAY'S PLAN — the week strip, today's schedule, and tonight's dinner in one card.
                todaysPlanCard.tabEntrance(.cascade, index: 3)

                // (e) GLANCES — quieter, de-emphasized: the house, the family, and slim shortcuts.
                glancesSection.tabEntrance(.pop, index: 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        // Tapping a radar row (from the card OR the pushed detail list) pushes the linked document.
        .navigationDestination(item: $store.scope(state: \.docDetail, action: \.docDetail)) { detailStore in
            DocumentDetailView(store: detailStore)
        }
        // P17-C1: tap a schedule row → edit the event in the Calendar tab's own form (sheet).
        .sheet(item: $store.scope(state: \.eventForm, action: \.eventForm)) { formStore in
            EventFormView(store: formStore)
        }
        // P17-C1: tap a family member card → their lightweight "day" sheet.
        .sheet(item: Binding(
            get: { store.memberDay },
            set: { if $0 == nil { store.send(.memberDayDismissed) } }
        )) { selection in
            MemberDaySheet(store: store, memberID: selection.id)
        }
        // P17-C1: "Change dinner" → the recipe picker (reuses the meal-plan assignment path).
        .sheet(isPresented: Binding(
            get: { store.showDinnerPicker },
            set: { if !$0 { store.send(.dinnerPickerDismissed) } }
        )) {
            DinnerPickerSheet(store: store)
        }
        // Act V — V2-D: the smart-capture inbox. One sheet that AI-routes a photo/note anywhere.
        .sheet(item: $store.scope(state: \.capture, action: \.capture)) { captureStore in
            CaptureView(store: captureStore)
        }
        // FL2 — "Make a memory" from the new-photo nudge opens the rich in-app photo browser; its
        // selected asset ids are handed to the existing memory-create path (no MemoriesFeature edits).
        .sheet(isPresented: Binding(
            get: { store.showPhotoBrowser },
            set: { if !$0 { store.send(.photoBrowserDismissed) } }
        )) {
            PhotoLibraryBrowser { assetIDs in
                store.send(.photoNudgeAssetsPicked(assetIDs))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.send(.captureTapped) } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Capture anything")
                .accessibilityIdentifier("today-capture-button")
            }
        }
        .task { store.send(.task) }
        .refreshable { await store.send(.task).finish() }
    }

    // MARK: Needs you today (consolidated: Family Radar + overdue care + today's chores)

    /// One prioritized row in the "Needs you today" list. Wraps whichever of the three merged sources
    /// a row came from — a Family-Radar document alert, an overdue care task, a due-soon (not-yet-
    /// overdue) care task, or a chore due today — so they can be sorted into one urgency order while
    /// each keeps its own inline action (add-to-calendar / renew, mark-care-done + celebration,
    /// complete-chore). The `(bucket, tiebreak)` pair is the sort key; lower = more urgent.
    private struct NeedRow: Identifiable {
        enum Kind {
            case radarDoc(FamilyRadar.Item)          // a Brain doc alert (expired or upcoming)
            case overdueCare(FamilyRadar.CareRadarItem)  // an overdue house/pet/plant task
            case dueSoonCare(CareItem.CareDue)        // a not-yet-overdue care task, due within a week
            case chore(Chore)                          // a chore due today / overdue / undated
            case projectDeadline(Project, days: Int)   // a project whose target date is approaching
        }
        let id: String
        let kind: Kind
        let bucket: Int
        let tiebreak: Double
    }

    /// The urgency cap for the compact card — the rest spill into the quiet "See all" footers so the
    /// list stays glanceable rather than a wall.
    private let needsVisibleCap = 6

    /// Projects PR5 — a project's target date only earns a "Needs you today" nudge when it's genuinely
    /// approaching: within this many days AND not already past. One soft row per project, at most — so
    /// the list never floods with distant targets or per-task noise.
    private let projectDeadlineWindow = 30

    /// Build the merged, urgency-sorted "needs you" list. Overdue care comes from the radar (which
    /// summarizes the 32-plant watering flood into one row); due-soon-but-not-overdue care comes from
    /// the care roster (so upcoming upkeep isn't lost) — the two never overlap (overdue vs not).
    private func needRows() -> [NeedRow] {
        var rows: [NeedRow] = []
        let radar = store.state.radar(now: now)
        // Loud document alerts: expired shouted first (bucket 0), upcoming later (bucket 5).
        for item in radar.all {
            rows.append(NeedRow(
                id: "radar-\(item.doc.id)", kind: .radarDoc(item),
                bucket: item.isExpired ? 0 : 5, tiebreak: Double(item.days)
            ))
        }
        // Overdue care (bucket 1) — most-overdue first.
        for care in radar.care {
            rows.append(NeedRow(
                id: "care-\(care.id)", kind: .overdueCare(care),
                bucket: 1, tiebreak: Double(-care.daysOver)
            ))
        }
        // Due-soon care that ISN'T overdue (bucket 3 due-today / bucket 4 upcoming). Overdue ones are
        // already covered by `radar.care`, so filtering them out here avoids any double-listing.
        for due in careDue() where !due.isOverdue {
            rows.append(NeedRow(
                id: "duecare-\(due.id)", kind: .dueSoonCare(due),
                bucket: due.days <= 0 ? 3 : 4, tiebreak: Double(due.days) + 0.5
            ))
        }
        // Chores: overdue (bucket 2) ahead of due-today/undated (bucket 3).
        for chore in choresToday() {
            let days = choreDaysUntil(chore)
            rows.append(NeedRow(
                id: "chore-\(chore.id)", kind: .chore(chore),
                bucket: days < 0 ? 2 : 3, tiebreak: Double(days)
            ))
        }
        // Projects (bucket 5, soft): one gentle nudge per active project whose target date is within the
        // window and not yet past — sorted just AFTER same-day document alerts (tiebreak +0.3) so an
        // upcoming deadline reads as the calm, low-urgency item it is.
        for row in projectDeadlineRows() {
            rows.append(row)
        }
        return rows.sorted { ($0.bucket, $0.tiebreak) < ($1.bucket, $1.tiebreak) }
    }

    /// Whole days until a chore is due (`< 0` overdue, `0` today/undated).
    private func choreDaysUntil(_ chore: Chore) -> Int {
        guard let due = chore.dueDate else { return 0 }
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day ?? 0
    }

    /// Projects PR5 — the soft "Needs you today" deadline nudges. One row per active project whose
    /// target date lands within `projectDeadlineWindow` days and is not yet past (`0…window`). Kept
    /// deliberately sparse: no per-task rows, no distant targets — just an approaching finish line.
    private func projectDeadlineRows() -> [NeedRow] {
        let today = cal.startOfDay(for: now)
        return store.activeProjects.compactMap { project in
            guard let target = project.targetDate else { return nil }
            let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: target)).day ?? 0
            guard days >= 0, days <= projectDeadlineWindow else { return nil }
            return NeedRow(
                id: "project-\(project.id)", kind: .projectDeadline(project, days: days),
                bucket: 5, tiebreak: Double(days) + 0.3
            )
        }
    }

    /// The consolidated card. With work to do → a counted, prioritized list capped at `needsVisibleCap`
    /// with quiet "See all" footers; nothing to do → a warm caught-up card.
    @ViewBuilder
    private var needsYouCard: some View {
        let rows = needRows()
        if rows.isEmpty {
            caughtUpCard
        } else {
            let visible = Array(rows.prefix(needsVisibleCap))
            card {
                needsHeader(count: rows.count)
                VStack(spacing: 12) {
                    ForEach(visible) { row in needRowView(row) }
                    needsFooters(rows: rows)
                }
            }
            .accessibilityIdentifier("today-needs-you")
        }
    }

    private func needsHeader(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "bell.badge.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.terracotta)
                Text("Needs you today")
                    .familyTitle(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
                Text("\(count)")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.terracotta))
                    .accessibilityIdentifier("today-needs-you-count")
            }
            Text(count == 1 ? "1 thing needs you" : "\(count) things need you")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Color.inkSoft)
        }
    }

    @ViewBuilder
    private func needRowView(_ row: NeedRow) -> some View {
        switch row.kind {
        case let .radarDoc(item):
            RadarRow(store: store, item: item)
        case let .overdueCare(care):
            CareRadarRow(store: store, item: care)
        case let .dueSoonCare(due):
            TodayCareRow(
                due: due,
                isJustDone: store.careCelebration?.itemID == due.item.id
                    && store.careCelebration?.taskID == due.task.id,
                onOpen: { store.send(.careRowTapped(itemID: due.item.id)) },
                onMarkDone: { store.send(.markCareTaskDone(itemID: due.item.id, taskID: due.task.id)) },
                onUndo: { store.send(.undoCareTaskDone(itemID: due.item.id, taskID: due.task.id), animation: .snappy) },
                onSnooze: { days in store.send(.snoozeCareTask(itemID: due.item.id, taskID: due.task.id, days: days), animation: .snappy) }
            )
        case let .chore(chore):
            choreRow(chore)
        case let .projectDeadline(project, days):
            ProjectDeadlineRow(project: project, days: days) {
                store.send(.projectOpenTapped(id: project.id))
            }
        }
    }

    /// The quiet progressive-disclosure footers for whatever spilled past the cap. Home-side overflow
    /// (chores + due-soon care) → the Home tab; radar-side overflow (doc alerts + overdue care), or any
    /// calm "Records", → the full Family Radar list. Two links at most, and only when there's more.
    @ViewBuilder
    private func needsFooters(rows: [NeedRow]) -> some View {
        let hidden = rows.dropFirst(needsVisibleCap)
        let hiddenHome = hidden.filter { row in
            switch row.kind { case .chore, .dueSoonCare: return true; default: return false }
        }.count
        // Project-deadline rows belong to neither the Home tab nor Family Radar — exclude them so a
        // spilled project nudge never inflates (and mislabels) the "See all in Family Radar" footer.
        let hiddenProjects = hidden.filter { row in
            if case .projectDeadline = row.kind { return true }; return false
        }.count
        let hiddenRadar = hidden.count - hiddenHome - hiddenProjects
        let radar = store.state.radar(now: now)
        if hiddenHome > 0 {
            footerLink(
                "\(hiddenHome) more in Home", symbol: "arrow.forward.circle",
                id: "today-needs-more-home"
            ) { store.send(.openHomeTapped(card: "needs_you")) }
        }
        if hiddenRadar > 0 || !radar.records.isEmpty {
            NavigationLink {
                RadarDetailView(store: store)
            } label: {
                footerLabel("See all in Family Radar", symbol: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-needs-see-all-radar")
        }
    }

    private func footerLink(
        _ text: String, symbol: String, id: String, _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { footerLabel(text, symbol: symbol) }
            .buttonStyle(.pressable)
            .accessibilityIdentifier(id)
    }

    private func footerLabel(_ text: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
        }
        .font(.system(.subheadline, design: .rounded).weight(.semibold))
        .foregroundStyle(Color.bacanGreen)
        .contentShape(Rectangle())
    }

    /// The warm empty state — nothing needs the family right now.
    private var caughtUpCard: some View {
        card {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Color.bacanGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all caught up 🌤️")
                        .familyTitle(.headline)
                        .foregroundStyle(Color.ink)
                    Text("Nothing needs you right now — enjoy it.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier("today-needs-you-caughtup")
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
        let hour = cal.component(.hour, from: now)
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
        return "\(f.string(from: now)) at the Place house"
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

    // MARK: Week strip (P28 — the calendar, folded into Today)

    /// A horizontal 7-day glance for the week containing `now`. Each day shows its weekday initial,
    /// date, and an event-dot when anything's scheduled; the day-of is ringed, the selected day is
    /// filled. Tapping a day re-scopes the schedule card below. Backed by the same client-side
    /// occurrence expansion the agenda uses.
    private var weekStrip: some View {
        let days = weekDays()
        return HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in weekDayCell(day) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("today-week-strip")
    }

    private func weekDayCell(_ day: Date) -> some View {
        let isToday = cal.isDate(day, inSameDayAs: now)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDay)
        let count = occurrenceCount(on: day)
        return Button {
            store.send(.selectDay(day))
        } label: {
            VStack(spacing: 4) {
                Text(weekdayInitial(day))
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(isSelected ? .white : Color.inkSoft)
                Text("\(cal.component(.day, from: day))")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(isSelected ? .white : Color.ink)
                Circle()
                    .fill(count > 0 ? (isSelected ? Color.white : Color.bacanGreen) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.bacanGreen : Color.familySurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isToday && !isSelected ? Color.bacanGreen : .clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-week-day-\(cal.component(.day, from: day))")
    }

    /// The seven days of the week (respecting the locale's first weekday) that contains `now`.
    private func weekDays() -> [Date] {
        let start = cal.startOfDay(for: now)
        guard let interval = cal.dateInterval(of: .weekOfYear, for: start) else { return [start] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func weekdayInitial(_ day: Date) -> String {
        let idx = cal.component(.weekday, from: day) - 1
        return cal.veryShortWeekdaySymbols[idx]
    }

    // MARK: Schedule (scoped to the week strip's selected day)

    // MARK: Today's plan (week strip + schedule + tonight's dinner, one compact card)

    /// (d) The compact "Today's plan" card — the week strip up top, then today's schedule and tonight's
    /// dinner as two light subsections divided by a hairline. Both keep every inline action they had as
    /// standalone cards (tap-to-edit events, add-event, open-calendar, change-dinner, add-to-calendar).
    private var todaysPlanCard: some View {
        card {
            cardHeader("Today's plan", symbol: "sun.max.fill")
            weekStrip

            planDivider

            HStack {
                subHeader(scheduleTitle, symbol: "calendar")
                Spacer()
                addEventButton
            }
            scheduleContent
            openCalendarRow

            planDivider

            HStack {
                subHeader("Tonight's dinner", symbol: "fork.knife")
                Spacer()
                changeDinnerButton
            }
            dinnerBody
        }
        .accessibilityIdentifier("today-plan")
    }

    private var planDivider: some View {
        Divider().overlay(Color.inkSoft.opacity(0.15)).padding(.vertical, 2)
    }

    private var addEventButton: some View {
        Button { store.send(.quickAddEventTapped) } label: {
            Label("Add event", systemImage: "plus.circle.fill")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-schedule-add-event")
    }

    /// Time-aware schedule body (P17-C1, P28). For the day-of, the day is split at `now`: all-day events
    /// pin at the top, upcoming/in-progress timed events follow, and events whose end already passed
    /// collapse under an "Earlier today" disclosure. For any OTHER selected day it's a plain agenda.
    @ViewBuilder
    private var scheduleContent: some View {
        let isToday = cal.isDate(store.selectedDay, inSameDayAs: now)
        let all = occurrences(on: store.selectedDay)
        if all.isEmpty {
            emptyLine(isToday ? "Nothing on the books — a rare quiet day." : "Nothing scheduled.")
        } else if isToday {
            todayScheduleBody(all)
        } else {
            VStack(spacing: 12) {
                ForEach(all) { item in scheduleRow(item) }
            }
        }
    }

    /// The day-of body: all-day + upcoming up top, earlier-today collapsed beneath.
    @ViewBuilder
    private func todayScheduleBody(_ all: [TodayOccurrence]) -> some View {
        let allDay = all.filter { $0.event.isAllDay }
        let timed = all.filter { !$0.event.isAllDay }
        let upcoming = timed.filter { occurrenceEnd($0) >= now }
        let earlier = timed.filter { occurrenceEnd($0) < now }
        let primary = allDay + upcoming
        VStack(spacing: 12) {
            if primary.isEmpty {
                emptyLine("That's a wrap on today 🌙")
            } else {
                ForEach(primary) { item in scheduleRow(item) }
            }
            if !earlier.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 12) {
                        ForEach(earlier) { item in scheduleRow(item, past: true) }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Earlier today (\(earlier.count))")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                }
                .tint(Color.inkSoft)
                .accessibilityIdentifier("today-schedule-earlier")
            }
        }
    }

    /// "Today's schedule" for the day-of; otherwise the selected day, e.g. "Mon, Jul 7".
    private var scheduleTitle: String {
        if cal.isDate(store.selectedDay, inSameDayAs: now) { return "Today's schedule" }
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f.string(from: store.selectedDay)
    }

    /// "Open full calendar ›" — pushes the untouched `CalendarFeature` (month grid + recurrence +
    /// Apple two-way sync) as a drill-in. The parent (MainTabReducer) drives the navigation.
    private var openCalendarRow: some View {
        Button { store.send(.openFullCalendarTapped) } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text("Open full calendar")
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.bacanGreen)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .padding(.top, 2)
        .accessibilityIdentifier("today-open-full-calendar")
    }

    private func scheduleRow(_ item: TodayOccurrence, past: Bool = false) -> some View {
        Button {
            store.send(.eventTapped(item.event))
        } label: {
            HStack(spacing: 12) {
                Text(item.event.isAllDay ? "All day" : timeString(item.date))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(past ? Color.inkSoft : Color.bacanGreen)
                    .frame(width: 64, alignment: .leading)
                Text(item.event.title)
                    .foregroundStyle(past ? Color.inkSoft : Color.ink)
                    .strikethrough(past, color: Color.inkSoft)
                Spacer()
                assigneeDots(item.event.assigneeIDs)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.inkSoft.opacity(0.5))
            }
            .contentShape(Rectangle())
            .opacity(past ? 0.7 : 1)
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-schedule-row-\(item.event.id)")
    }

    /// The occurrence's end instant: the base event's duration applied to this occurrence's start
    /// (recurring events keep their length), falling back to the start when there's no end.
    private func occurrenceEnd(_ item: TodayOccurrence) -> Date {
        if let end = item.event.endDate {
            let duration = end.timeIntervalSince(item.event.startDate)
            if duration > 0 { return item.date.addingTimeInterval(duration) }
        }
        return item.date
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

    /// After the dinner cutoff hour (8pm local) the card stops prompting and flips to a warm
    /// done/rest state. Uses the injected `now` so the sim clock drives it.
    private let dinnerCutoffHour = 20
    private var isPastDinnerHour: Bool { cal.component(.hour, from: now) >= dinnerCutoffHour }

    /// P17-C1 — always-available "Change dinner" (opens the recipe picker). Lives in the Today's-plan
    /// card's dinner subsection header.
    private var changeDinnerButton: some View {
        Button { store.send(.changeDinnerTapped) } label: {
            Label("Change", systemImage: "arrow.triangle.2.circlepath")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-dinner-change")
    }

    @ViewBuilder
    private var dinnerBody: some View {
        if isPastDinnerHour {
            // Evening rest state — stop nagging once dinnertime has passed.
            let line = tonightsEntry != nil
                ? "Dinner's done — hope it was good 🌙"
                : "Kitchen's closed for the night 🌙"
            Text(line)
                .foregroundStyle(Color.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("today-dinner-evening")
        } else if let entry = tonightsEntry, entry.isEatingOut {
            eatingOutContent(entry)
        } else if let title = tonightsDinnerTitle {
            // Tap the dish → open that recipe in Kitchen (its detail), not a dead label.
            Button { store.send(.dinnerRecipeTapped) } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .familyTitle()
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.inkSoft.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-dinner-recipe")
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
        store.mealPlan.first { cal.isDate($0.date, inSameDayAs: now) }
    }

    private var tonightsDinnerTitle: String? {
        guard let entry = tonightsEntry, !entry.isEatingOut else { return nil }
        // Prefer the live recipe title (renames), falling back to the stored snapshot.
        return store.recipes.first { $0.id == entry.recipeID }?.title ?? entry.recipeTitle
    }

    // MARK: Glances (quieter, lower — the house, the family, slim shortcuts)

    /// (e) The de-emphasized bottom of Today: a quiet "Around the house" label, the (optional) house
    /// card, the family grid, and a slim shortcuts row. Everything here is a glance or a secondary
    /// entry point — it never competes with "Needs you today" or "Today's plan" above.
    private var glancesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Around the house")
            projectsCard
            houseCard
            familyCard
            shortcutsRow
        }
    }

    // MARK: Projects glance (PR5)

    /// A calm glance at the family's active initiatives (pool build, school hunt) — one quiet card that
    /// lists each project with its cover, phase, and a hint. Hidden entirely when nothing's active, so
    /// it never nags an empty-handed family. Tapping a row lands on the Projects list under Lists.
    @ViewBuilder
    private var projectsCard: some View {
        let projects = store.activeProjects
        if !projects.isEmpty {
            card {
                cardHeader("Projects", symbol: "hammer.fill")
                VStack(spacing: 12) {
                    ForEach(projects) { project in
                        ProjectGlanceRow(project: project, hint: projectHint(project)) {
                            store.send(.projectOpenTapped(id: project.id))
                        }
                    }
                }
            }
            .accessibilityIdentifier("today-projects")
        }
    }

    /// The one-line hint under a project's name, in usefulness order: the next open task ("Next: Call
    /// three builders"), else an approaching/known target-date countdown, else a plain task count, else
    /// a soft phase nudge. Kept to a single glanceable line.
    private func projectHint(_ project: Project) -> String {
        if let next = (project.tasks ?? []).first(where: { !$0.isDone }) {
            let title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return "Next: \(title)" }
        }
        if let target = project.targetDate {
            return "Target \(Self.targetMonth(target)) · \(targetCountdown(target))"
        }
        if let tasks = project.tasks, !tasks.isEmpty {
            return tasks.count == 1 ? "1 task" : "\(tasks.count) tasks"
        }
        return project.status.displayName
    }

    /// "Jun 2027" — the month a target date lands in.
    private static func targetMonth(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }

    /// A soft relative countdown to a target date: "today", "in 9 days", "in 3 wk", "in 11 mo",
    /// "in 2 yr", or "passed" once it's behind us. Coarsened on purpose — a glance, not a stopwatch.
    private func targetCountdown(_ date: Date) -> String {
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        if days < 0 { return "passed" }
        if days == 0 { return "today" }
        if days < 14 { return "in \(days) days" }
        if days < 60 { return "in \(days / 7) wk" }
        if days < 365 { return "in \(max(1, days / 30)) mo" }
        return "in \(max(1, days / 365)) yr"
    }

    /// A slim, single row of secondary entry points — the three deep-links plus a warm "capture a
    /// moment". Demoted from the old big cards to quiet, equal-weight chips so there's one calm shelf
    /// of shortcuts instead of several competing calls-to-action. (Smart-capture stays on the toolbar +.)
    private var shortcutsRow: some View {
        HStack(spacing: 10) {
            quickAction("Event", symbol: "calendar.badge.plus") { store.send(.quickAddEventTapped) }
            quickAction("List", symbol: "checklist") { store.send(.quickAddListTapped) }
            quickAction("Dinner", symbol: "fork.knife") { store.send(.planDinnerTapped) }
            quickAction("Moment", symbol: "camera.fill") { store.send(.captureMomentTapped) }
        }
        .accessibilityIdentifier("today-shortcuts")
    }

    /// A quiet, uppercase section label — creates top-level rhythm without competing with card headers.
    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .foregroundStyle(Color.inkSoft)
            .tracking(0.8)
            .padding(.horizontal, 4)
    }

    /// A lighter sub-section header used inside the "Today's plan" card (schedule / dinner).
    private func subHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
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
        let startOfToday = cal.startOfDay(for: now)
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

    private func choreRow(_ chore: Chore) -> some View {
        let assignee = store.members.first { $0.id == chore.assigneeID }
        let color = assignee.map(memberColor) ?? .bacanGreen
        return HStack(spacing: 12) {
            // The checkbox still completes in place (server awards/reverses XP) — no navigation.
            Button { store.send(.toggleChore(chore)) } label: {
                Image(systemName: chore.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chore.isCompleted ? color : Color.inkSoft)
                    .stickerSlap(isOn: chore.isCompleted, color: color)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-chore-toggle-\(chore.id)")

            // The rest of the row is a tap target → the Home tab's Chores & rewards board, where the
            // chore lives (no per-chore screen exists).
            Button { store.send(.choreRowTapped) } label: {
                HStack(spacing: 12) {
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
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.inkSoft.opacity(0.5))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-chore-row-\(chore.id)")
        }
    }

    // MARK: Home care (P8-C2)

    /// Care tasks due or overdue within a week, same math as the Home tab's House-care banner.
    private func careDue() -> [CareItem.CareDue] {
        CareItem.dueTasks(in: store.careItems)
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
                nestConfig: store.nestConfig, hubspaceConfig: store.hubspaceConfig,
                merossConfig: store.merossConfig, homekitConfig: store.homekitConfig
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
        return Button {
            store.send(.memberTapped(member.id))
        } label: {
            VStack(spacing: 6) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-member-\(member.id)")
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
        occurrences(on: now)
    }

    /// Every materialized occurrence on the given day, sorted by start (all-day events sort by their
    /// day-start). Shared by the week strip, the schedule card, and the family tiles.
    private func occurrences(on day: Date) -> [TodayOccurrence] {
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return store.events
            .flatMap { event in
                event.occurrences(from: start, to: end, calendar: cal)
                    .map { TodayOccurrence(event: event, date: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    /// How many events fall on the given day — drives the week strip's event-dot.
    private func occurrenceCount(on day: Date) -> Int {
        occurrences(on: day).count
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
    /// D1.5 — this row's completion is still in its celebration/undo window (the reducer is holding it).
    /// While true, a tap on the done glyph REVERSES it (toggle-to-undo) instead of re-completing.
    var isJustDone: Bool = false
    /// Tap the row body → drill into the Home tab (where the plant/pet/upkeep item lives).
    let onOpen: () -> Void
    let onMarkDone: () -> Void
    /// D1.5 — reverse an accidental completion (toast Undo + tap-to-toggle both call this).
    var onUndo: () -> Void = {}
    /// D1.5 — "not yet, the soil's still damp": push the next-due out N days without completing.
    var onSnooze: (Int) -> Void = { _ in }

    /// Bumps on each mark-done tap → flavored burst + glyph morph + leading-icon bounce.
    @State private var careTrigger = 0

    /// The CelebrationKit flavor for this due item (kind + task verb).
    private var style: CelebrationStyle { .forCare(kind: due.item.kind, taskTitle: due.task.title) }

    var body: some View {
        HStack(spacing: 12) {
            // The name + due chip are a tap target → the Home tab. The trailing glyph still marks done
            // in place, firing the flavored celebration.
            Button {
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: due.item.iconSymbol)
                        .font(.subheadline)
                        .foregroundStyle(due.isOverdue ? Color.terracotta : Color.bacanGreen)
                        .frame(width: 22)
                        .careBounce(trigger: careTrigger) // the item perks up when cared for
                    Text(due.item.name)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer()
                    dueChip
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            Button {
                if isJustDone {
                    // Toggle-to-undo: a second tap during the celebration window reverses the completion.
                    MenereHaptics.softTap()
                    onUndo()
                } else {
                    onMarkDone()
                    careTrigger += 1
                    MenereHaptics.celebrate(style)
                }
            } label: {
                CelebrationGlyph(trigger: careTrigger, style: style, size: 20)
            }
            .buttonStyle(.pressable)
            .careCelebration(trigger: careTrigger, style: style, name: due.item.name, onUndo: onUndo)
            .contextMenu {
                Button { onSnooze(3) } label: {
                    Label("Not yet — soil's still damp (+3 days)", systemImage: "moon.zzz")
                }
                Button { onSnooze(7) } label: {
                    Label("Snooze a week", systemImage: "moon.zzz.fill")
                }
                if isJustDone {
                    Button(role: .destructive) { onUndo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .accessibilityLabel(isJustDone ? "Undo \(due.item.name)" : "Mark \(due.item.name) done")
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

/// A single Family Radar row (P20), shared by the Today card and the Radar detail list so they speak
/// with one voice. The leading region (icon + humanized label + date chip) is a tap target → opens the
/// linked document; the trailing region carries the item's one-tap, idempotent action (add-to-calendar
/// for an upcoming due date, "renew" reminder for an expired vaccine).
private struct RadarRow: View {
    let store: StoreOf<TodayReducer>
    let item: FamilyRadar.Item

    var body: some View {
        HStack(spacing: 12) {
            Button {
                store.send(.radarItemTapped(docID: item.doc.id))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: leadingSymbol)
                        .font(.subheadline)
                        .foregroundStyle(item.isExpired ? Color.terracotta : Color.marigold)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        DocumentDateChip(date: item.date, kind: item.kind == .expiry ? .expiry : .due)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .contextMenu {
                Button {
                    store.send(.radarItemDismissed(docID: item.doc.id))
                } label: {
                    Label("Snooze 90 days", systemImage: "bell.slash")
                }
                .accessibilityIdentifier("today-radar-dismiss-\(item.doc.id)")
            }

            trailingAction
        }
        .accessibilityIdentifier("today-radar-row-\(item.doc.id)")
    }

    /// EXPIRED reads LOUD with a warning triangle; otherwise the pet/doc-type glyph.
    private var leadingSymbol: String {
        item.isExpired ? "exclamationmark.triangle.fill" : item.iconSymbol
    }

    @ViewBuilder
    private var trailingAction: some View {
        if item.isExpired, item.isVaccine {
            if store.state.radarRenewScheduled(item) {
                doneChip
            } else {
                actionButton(systemImage: "bell.badge", tint: .terracotta) {
                    store.send(.radarRenewReminderTapped(docID: item.doc.id))
                }
                .accessibilityLabel("Add a reminder to renew")
                .accessibilityIdentifier("today-radar-renew-\(item.doc.id)")
            }
        } else if item.doc.dueDate != nil, !item.isExpired {
            if store.state.radarOnCalendar(item) {
                doneChip
            } else {
                actionButton(systemImage: "calendar.badge.plus", tint: .bacanGreen) {
                    store.send(.radarAddToCalendarTapped(docID: item.doc.id))
                }
                .accessibilityLabel("Add to calendar")
                .accessibilityIdentifier("today-radar-add-\(item.doc.id)")
            }
        }
    }

    private func actionButton(systemImage: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.pressable)
    }

    private var doneChip: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(Color.bacanGreen)
            .frame(width: 30, height: 30)
            .accessibilityLabel("Done")
    }
}

/// A single Family Radar CARE row (P20 care extension) — an OVERDUE care task (house/pet/plant)
/// promoted onto the radar. Visually distinct from a doc alert: the care item's own glyph (leaf /
/// pawprint / house) + a terracotta "Nd over" chip, and NO loud warning triangle (overdue care is
/// attention-worthy, not doc-expired red). Actionable rows (a single task) carry a one-tap "mark
/// done"; the grouped "N plants need water" summary is informational (no single task to complete).
private struct CareRadarRow: View {
    let store: StoreOf<TodayReducer>
    let item: FamilyRadar.CareRadarItem

    /// Bumps on each mark-done tap → flavored burst + glyph morph.
    @State private var careTrigger = 0

    private var style: CelebrationStyle { .forRadar(item.category) }

    var body: some View {
        HStack(spacing: 12) {
            // The leading region (icon + label + chip) drills ON the care item's Home detail — a pet
            // alert lands on that pet's profile, a plant/house task on its detail. Only tappable when
            // this row stands for a single item (the grouped "N plants need water" summary has no id).
            Button {
                if let careItemID = item.careItemID {
                    store.send(.radarCareRowTapped(itemID: careItemID))
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.iconSymbol)
                        .font(.subheadline)
                        .foregroundStyle(Color.terracotta)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        overdueChip
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(item.careItemID == nil)
            .accessibilityIdentifier("today-radar-care-open-\(item.id)")
            if item.isActionable, let careItemID = item.careItemID, let taskID = item.taskID {
                let isJustDone = store.careCelebration?.itemID == careItemID
                    && store.careCelebration?.taskID == taskID
                Button {
                    if isJustDone {
                        MenereHaptics.softTap()
                        store.send(.undoCareTaskDone(itemID: careItemID, taskID: taskID), animation: .snappy)
                    } else {
                        store.send(.radarCareItemMarkedDone(itemID: careItemID, taskID: taskID))
                        careTrigger += 1
                        MenereHaptics.celebrate(style)
                    }
                } label: {
                    CelebrationGlyph(trigger: careTrigger, style: style, size: 21)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.pressable)
                .careCelebration(
                    trigger: careTrigger, style: style, name: item.label,
                    onUndo: { store.send(.undoCareTaskDone(itemID: careItemID, taskID: taskID), animation: .snappy) }
                )
                .contextMenu {
                    Button { store.send(.snoozeCareTask(itemID: careItemID, taskID: taskID, days: 3), animation: .snappy) } label: {
                        Label("Not yet — soil's still damp (+3 days)", systemImage: "moon.zzz")
                    }
                    Button { store.send(.snoozeCareTask(itemID: careItemID, taskID: taskID, days: 7), animation: .snappy) } label: {
                        Label("Snooze a week", systemImage: "moon.zzz.fill")
                    }
                    if isJustDone {
                        Button(role: .destructive) { store.send(.undoCareTaskDone(itemID: careItemID, taskID: taskID), animation: .snappy) } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                .accessibilityLabel(isJustDone ? "Undo" : (item.category == .plant ? "Water" : "Mark done"))
                .accessibilityIdentifier("today-radar-care-done-\(item.id)")
            }
        }
        .accessibilityIdentifier("today-radar-care-\(item.id)")
    }

    /// Terracotta "Nd over" chip — overdue care is late, but calmer than an expired-doc alarm.
    private var overdueChip: some View {
        Text(item.daysOver <= 0 ? "Due" : "\(item.daysOver)d over")
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.terracotta)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.terracotta.opacity(0.14)))
    }
}

/// A calm, muted Family Radar record row (P20-C2) — a past-dated HISTORICAL doc demoted out of the
/// alarm. No warning triangle, no red, no action; the doc-type glyph + humanized label + a quiet
/// "· 2023" year. Tapping still opens the linked document.
private struct RadarRecordRow: View {
    let store: StoreOf<TodayReducer>
    let item: FamilyRadar.Item

    var body: some View {
        Button {
            store.send(.radarItemTapped(docID: item.doc.id))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.iconSymbol)
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
                    .frame(width: 22)
                Text(item.label)
                    .foregroundStyle(Color.inkSoft)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("· \(item.recordSubtitle)")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-radar-record-\(item.doc.id)")
    }
}

/// The full Family Radar list (P20) — every expired + upcoming item grouped Expired / This month /
/// Later, most-urgent first. Reached via the card's "See all" row. Reuses ``RadarRow`` so a row taps
/// through to its document and carries the same one-tap actions.
private struct RadarDetailView: View {
    let store: StoreOf<TodayReducer>

    var body: some View {
        ScrollView {
            let radar = store.state.radar()
            let thisMonth = radar.upcoming.filter { $0.days <= 30 }
            let later = radar.upcoming.filter { $0.days > 30 }
            VStack(alignment: .leading, spacing: 20) {
                group("Expired", symbol: "exclamationmark.triangle.fill", tint: .terracotta, items: radar.expired)
                careGroup(radar.care)
                group("This month", symbol: "calendar", tint: .marigold, items: thisMonth)
                group("Later", symbol: "clock", tint: .inkSoft, items: later)
                if radar.isEmpty && radar.records.isEmpty {
                    Text("Nothing needs your attention 🟢 You're all caught up.")
                        .foregroundStyle(Color.inkSoft)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 40)
                }
                recordsDisclosure(radar.records)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle("Family Radar")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.radarOpened) }
    }

    /// P20-C2 — a calm, collapsed "Records" disclosure for past-dated HISTORICAL docs (a COVID card,
    /// a vet visit). Muted, no warning triangle, no red — "Rabies card · 2023" style; taps still open
    /// the document. Deliberately quiet so it never competes with the loud renewable alerts.
    @ViewBuilder
    private func recordsDisclosure(_ records: [FamilyRadar.Item]) -> some View {
        if !records.isEmpty {
            DisclosureGroup {
                VStack(spacing: 12) {
                    ForEach(records) { item in RadarRecordRow(store: store, item: item) }
                }
                .padding(.top, 12)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full").font(.subheadline).foregroundStyle(Color.inkSoft)
                    Text("Records").familyTitle(.headline).foregroundStyle(Color.ink)
                    Text("\(records.count)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                }
            }
            .tint(Color.inkSoft)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
            .accessibilityIdentifier("today-radar-records")
        }
    }

    /// The ACTIONABLE "Overdue care" section — house/pet/plant tasks past due, most-overdue first.
    /// Rendered as its own group between the loud doc "Expired" and the softer upcoming buckets.
    @ViewBuilder
    private func careGroup(_ items: [FamilyRadar.CareRadarItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill").font(.subheadline)
                        .foregroundStyle(Color.terracotta)
                    Text("Overdue care").familyTitle(.headline).foregroundStyle(Color.ink)
                    Text("\(items.count)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                }
                VStack(spacing: 12) {
                    ForEach(items) { item in CareRadarRow(store: store, item: item) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
            }
            .accessibilityIdentifier("today-radar-care-section")
        }
    }

    @ViewBuilder
    private func group(_ title: String, symbol: String, tint: Color, items: [FamilyRadar.Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.subheadline).foregroundStyle(tint)
                    Text(title).familyTitle(.headline).foregroundStyle(Color.ink)
                    Text("\(items.count)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                }
                VStack(spacing: 12) {
                    ForEach(items) { item in RadarRow(store: store, item: item) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
            }
        }
    }
}

/// A member's "day at a glance" (P17-C1) — a lightweight, read-mostly sheet reached by tapping a
/// family card on Today. Reuses the already-loaded events + chores in the Today store (no new fetch):
/// the member's avatar/level, their timed & all-day events today, and their open chores.
private struct MemberDaySheet: View {
    let store: StoreOf<TodayReducer>
    let memberID: String
    @Environment(\.dismiss) private var dismiss
    @Dependency(\.date.now) private var now
    private let cal = Calendar.current

    private var member: HouseholdMember? { store.members.first { $0.id == memberID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let member {
                        header(member)
                        eventsSection
                        choresSection
                    } else {
                        Text("This member's day isn't available.")
                            .foregroundStyle(Color.inkSoft)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.familyCanvas)
            .navigationTitle(member.map { firstName($0.name) } ?? "Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func header(_ member: HouseholdMember) -> some View {
        let rgb = member.color.rgb
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let level = (store.stats.first { $0.memberID == member.id } ?? MemberStats(id: member.id, memberID: member.id)).level
        return HStack(spacing: 14) {
            Image(systemName: member.avatarSystemName)
                .font(.largeTitle)
                .foregroundStyle(color)
                .frame(width: 56, height: 56)
                .background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(member.name)
                    .familyTitle(.title3)
                    .foregroundStyle(Color.ink)
                Text("Level \(level)")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var eventsSection: some View {
        let events = memberEvents()
        section("On the calendar", symbol: "calendar") {
            if events.isEmpty {
                Text("Nothing scheduled today.").foregroundStyle(Color.inkSoft)
            } else {
                ForEach(events) { item in
                    HStack(spacing: 12) {
                        Text(item.event.isAllDay ? "All day" : shortTime(item.date))
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                            .frame(width: 64, alignment: .leading)
                        Text(item.event.title).foregroundStyle(Color.ink)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var choresSection: some View {
        let chores = memberChores()
        section("Chores", symbol: "checklist") {
            if chores.isEmpty {
                Text("No open chores today. 🎉").foregroundStyle(Color.inkSoft)
            } else {
                ForEach(chores) { chore in
                    HStack(spacing: 12) {
                        Image(systemName: "circle").foregroundStyle(Color.inkSoft)
                        Text(chore.title).foregroundStyle(Color.ink)
                        Spacer(minLength: 0)
                        Text("\(chore.effectiveXP) XP")
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                    }
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String, symbol: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.subheadline).foregroundStyle(Color.inkSoft)
                Text(title).familyTitle(.headline).foregroundStyle(Color.ink)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
    }

    // MARK: Data (reuses the Today store — no new fetch)

    private func memberEvents() -> [TodayOccurrence] {
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return store.events
            .filter { $0.assigneeIDs.contains(memberID) }
            .flatMap { event in
                event.occurrences(from: start, to: end, calendar: cal)
                    .map { TodayOccurrence(event: event, date: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    private func memberChores() -> [Chore] {
        let startOfToday = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday)!
        return store.chores.filter { chore in
            guard chore.assigneeID == memberID, !chore.isCompleted else { return false }
            guard let due = chore.dueDate else { return true }   // undated counts as on-deck
            return due < endOfToday                                // overdue or today
        }
        .sorted { ($0.dueDate ?? $0.createdAt) < ($1.dueDate ?? $1.createdAt) }
    }

    private func firstName(_ full: String) -> String {
        full.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? full
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: date)
    }
}

/// The "Change dinner" picker (P17-C1) — a plain recipe list reached from the Today dinner card. A
/// tap assigns tonight's meal-plan entry through the same `saveMealPlanEntry` path the Kitchen tab
/// uses; there's no bespoke persistence here.
private struct DinnerPickerSheet: View {
    let store: StoreOf<TodayReducer>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.recipes.isEmpty {
                        Text("No recipes yet — add some in Kitchen first.")
                            .foregroundStyle(Color.inkSoft)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ForEach(store.recipes) { recipe in
                            Button {
                                store.send(.assignDinner(recipe))
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: recipe.isFavorite ? "star.fill" : "fork.knife")
                                        .foregroundStyle(recipe.isFavorite ? Color.marigold : Color.bacanGreen)
                                        .frame(width: 24)
                                    Text(recipe.title).foregroundStyle(Color.ink)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.inkSoft.opacity(0.5))
                                }
                                .contentShape(Rectangle())
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
                            }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("today-dinner-pick-\(recipe.id)")
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .background(Color.familyCanvas)
            .navigationTitle("Change dinner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Projects (PR5)

/// A project's lifecycle tint — a calm color per phase, used by the glance chip + cover placeholder.
private extension ProjectPhase {
    var tint: Color {
        switch self {
        case .dreaming: .sky
        case .researching, .deciding: .marigold
        case .inProgress, .done: .bacanGreen
        }
    }
}

/// A small pill naming a project's phase (icon + label), tinted by the phase. Shared by the glance row.
private struct PhaseChip: View {
    let phase: ProjectPhase

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: phase.icon)
                .font(.system(size: 9, weight: .bold))
            Text(phase.displayName)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(phase.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(phase.tint.opacity(0.14)))
    }
}

/// One row in the Today "Projects" glance (PR5): the project's cover thumb (or a phase-tinted glyph
/// placeholder), its name, a one-line hint (next task / target countdown / task count), and a phase
/// chip. The whole row taps through to the Projects list. Store-free so it previews on its own.
private struct ProjectGlanceRow: View {
    let project: Project
    let hint: String
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                cover
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(hint)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                PhaseChip(phase: project.status)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.inkSoft.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-project-\(project.id)")
    }

    private var cover: some View {
        BacanImage(path: project.coverImagePath, targetSize: CGSize(width: 88, height: 88)) {
            ZStack {
                Rectangle().fill(project.status.tint.opacity(0.14))
                Image(systemName: project.status.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(project.status.tint)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A soft "Needs you today" deadline nudge (PR5): a project whose target date is approaching. A muted
/// marigold flag + name + a "Target date in 3 weeks" chip; the whole row taps through to Projects. It
/// carries NO inline action — a deadline is a gentle heads-up, not a checkbox. Store-free for previews.
private struct ProjectDeadlineRow: View {
    let project: Project
    let days: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "flag.checkered")
                    .font(.subheadline)
                    .foregroundStyle(Color.marigold)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    deadlineChip
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.inkSoft.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-project-deadline-\(project.id)")
    }

    private var deadlineChip: some View {
        Text(phrase)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.marigold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.marigold.opacity(0.14)))
    }

    /// "Target date today / tomorrow / in N days / in N weeks" — coarsened so it reads calm, not tense.
    private var phrase: String {
        switch days {
        case ..<0: return "Target date passed"
        case 0: return "Target date today"
        case 1: return "Target date tomorrow"
        case 2..<14: return "Target date in \(days) days"
        default: return "Target date in \(max(1, Int((Double(days) / 7).rounded()))) weeks"
        }
    }
}

#if DEBUG
#Preview("Projects glance") {
    let pool = Project(
        name: "Backyard pool",
        status: .researching,
        targetDate: Calendar.current.date(byAdding: .month, value: 11, to: Date()),
        tasks: [
            ProjectTask(title: "Set a budget", isDone: true),
            ProjectTask(title: "Call three pool builders"),
        ]
    )
    let school = Project(
        name: "Oliver's big-kid school",
        status: .deciding,
        tasks: [ProjectTask(title: "Tour the Montessori open house")]
    )
    let reno = Project(name: "Kitchen refresh", status: .dreaming)
    return ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects").familyTitle(.headline).foregroundStyle(Color.ink)
            ProjectGlanceRow(project: pool, hint: "Next: Call three pool builders") {}
            ProjectGlanceRow(project: school, hint: "Next: Tour the Montessori open house") {}
            ProjectGlanceRow(project: reno, hint: "Dreaming") {}
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        .padding()
    }
    .background(Color.familyCanvas)
}

#Preview("Project deadline — Needs you today") {
    VStack(spacing: 12) {
        ProjectDeadlineRow(project: Project(name: "Backyard pool", status: .inProgress), days: 21) {}
        ProjectDeadlineRow(project: Project(name: "Oliver's school decision", status: .deciding), days: 5) {}
        ProjectDeadlineRow(project: Project(name: "Trip to Chile", status: .researching), days: 0) {}
    }
    .padding(16)
    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
    .padding()
    .background(Color.familyCanvas)
}
#endif
