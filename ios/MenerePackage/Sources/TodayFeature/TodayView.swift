import CalendarFeature
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import HouseFeature
import HueClient
import MenereUI
import SwiftUI

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
            VStack(alignment: .leading, spacing: 20) {
                // Motion & Delight — Today's signature: sections CASCADE top→bottom, and the
                // family grid POPS in with a sticker-slap overshoot. Replays on every (re)selection.
                greeting.tabEntrance(.cascade, index: 0)

                briefingCard.tabEntrance(.cascade, index: 1)

                captureAnythingButton.tabEntrance(.cascade, index: 2)

                // FL2 — the new-photo nudge (present only when there's a fresh batch / a soft opt-in).
                PhotoNudgeCard(store: store).tabEntrance(.cascade, index: 3)

                weekStrip.tabEntrance(.cascade, index: 3)
                scheduleCard.tabEntrance(.cascade, index: 4)
                dinnerCard.tabEntrance(.cascade, index: 5)
                quickActions.tabEntrance(.cascade, index: 6)
                captureMomentButton.tabEntrance(.cascade, index: 7)

                choresCard.tabEntrance(.cascade, index: 8)
                homeCareCard.tabEntrance(.cascade, index: 9)
                houseCard.tabEntrance(.cascade, index: 10)
                familyRadarCard.tabEntrance(.cascade, index: 11)
                familyCard.tabEntrance(.pop, index: 12)
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

    /// Act V — V2-D. The hero entry to the smart-capture inbox: the single fastest way to get anything
    /// into the app. Bacán decides where the photo/note goes; the user confirms.
    private var captureAnythingButton: some View {
        Button {
            store.send(.captureTapped)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Capture anything")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                    Text("A photo or a note — Bacán files it for you.")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.bacanGreen)
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-capture-hero")
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

    /// Time-aware schedule (P17-C1, P28). For the day-of, the day is split at `now`: all-day events
    /// pin at the top, upcoming/in-progress timed events follow, and events whose end already passed
    /// collapse under an "Earlier today" disclosure. For any OTHER selected day it's a plain agenda.
    /// The header carries "+ Add event"; an "Open full calendar" row sits at the foot.
    private var scheduleCard: some View {
        let isToday = cal.isDate(store.selectedDay, inSameDayAs: now)
        let all = occurrences(on: store.selectedDay)
        return card {
            HStack {
                cardHeader(scheduleTitle, symbol: "calendar")
                Spacer()
                Button { store.send(.quickAddEventTapped) } label: {
                    Label("Add event", systemImage: "plus.circle.fill")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("today-schedule-add-event")
            }

            if all.isEmpty {
                emptyLine(isToday ? "Nothing on the books — a rare quiet day." : "Nothing scheduled.")
            } else if isToday {
                todayScheduleBody(all)
            } else {
                VStack(spacing: 12) {
                    ForEach(all) { item in scheduleRow(item) }
                }
            }

            openCalendarRow
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

    private var dinnerCard: some View {
        card {
            HStack {
                cardHeader("Tonight's dinner", symbol: "fork.knife")
                Spacer()
                // P17-C1 — always-available "Change dinner" (opens the recipe picker).
                Button { store.send(.changeDinnerTapped) } label: {
                    Label("Change", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("today-dinner-change")
            }
            dinnerBody
        }
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

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction("Add event", symbol: "calendar.badge.plus") { store.send(.quickAddEventTapped) }
            quickAction("Add to list", symbol: "checklist") { store.send(.quickAddListTapped) }
            quickAction("Plan dinner", symbol: "fork.knife") { store.send(.planDinnerTapped) }
        }
    }

    /// P28-C2 — a warm entry to the family scrapbook, right in the flow of Today. Opens the same
    /// "capture a moment" editor as the Memories tab (via the `openMemories` delegate).
    private var captureMomentButton: some View {
        Button {
            store.send(.captureMomentTapped)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "camera.fill")
                    .font(.headline)
                Text("Capture a moment 📸")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.terracotta.opacity(0.6))
            }
            .foregroundStyle(Color.terracotta)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.terracotta.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.terracotta.opacity(0.28), lineWidth: 1)
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("today-capture-moment")
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
                        Button { store.send(.choreRowTapped) } label: {
                            HStack(spacing: 6) {
                                Text("+\(overflow) more in Home")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            }
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("today-chores-more")
                    }
                }
            }
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
                                store.send(.careRowTapped(itemID: item.item.id))
                            } onMarkDone: {
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

    // MARK: Family Radar (P20 — proactive alerts from latent document/vaccine dates)

    /// The radar's LOUD front door: EXPIRED items (a pet's rabies past its expiry) shouted first, then
    /// due/expiring-soon items, each tappable → the linked document. When there ARE documents but
    /// nothing needs attention, a calm caught-up line; nothing at all when the Brain is empty.
    @ViewBuilder
    private var familyRadarCard: some View {
        let radar = store.state.radar()
        if radar.isEmpty {
            if !store.documents.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.bacanGreen)
                    Text("Nothing needs your attention 🟢").foregroundStyle(Color.inkSoft)
                }
                .font(.system(.subheadline, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("today-radar-caughtup")
            }
        } else {
            let top = radar.topItems()
            // Overdue CARE rows share the card with the doc alerts — capped so the card stays
            // glanceable (the rest live in "See all"). Plant watering is already summarized upstream.
            let topCare = Array(radar.care.prefix(3))
            card {
                cardHeader("Family Radar", symbol: "dot.radiowaves.left.and.right")
                VStack(spacing: 12) {
                    ForEach(top) { item in RadarRow(store: store, item: item) }
                    ForEach(topCare) { item in CareRadarRow(store: store, item: item) }
                    // Surface the detail (which carries the care section + the calm "Records" list)
                    // when there are more loud items than fit, more care rows, OR records to browse.
                    if radar.all.count > top.count || radar.care.count > topCare.count
                        || !radar.records.isEmpty {
                        NavigationLink {
                            RadarDetailView(store: store)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "list.bullet")
                                Text("See all (\(radar.all.count + radar.care.count + radar.records.count))")
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            }
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("today-radar-see-all")
                    }
                }
            }
            .accessibilityIdentifier("today-family-radar")
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
    /// Tap the row body → drill into the Home tab (where the plant/pet/upkeep item lives).
    let onOpen: () -> Void
    let onMarkDone: () -> Void

    @State private var slapOn = false
    /// Bumps on each water tap → droplet burst + glyph morph + leading-icon bounce (plants only).
    @State private var waterTrigger = 0

    private var isPlant: Bool { due.item.kind == .plant }

    var body: some View {
        HStack(spacing: 12) {
            // The name + due chip are a tap target → the Home tab. The trailing droplet/check still
            // waters / marks done in place.
            Button {
                onOpen()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: due.item.iconSymbol)
                        .font(.subheadline)
                        .foregroundStyle(due.isOverdue ? Color.terracotta : Color.bacanGreen)
                        .frame(width: 22)
                        .plantBounce(trigger: waterTrigger) // the plant perks up when watered
                    Text(due.item.name)
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Spacer()
                    dueChip
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            if isPlant {
                // The dopamine path: watering fires the full celebration; the glyph morphs drop → check.
                Button {
                    onMarkDone()
                    waterTrigger += 1
                    MenereHaptics.water()
                } label: {
                    WaterGlyph(trigger: waterTrigger, size: 20, restSymbol: "drop.fill", tint: .sky)
                }
                .buttonStyle(.pressable)
                .waterCelebration(trigger: waterTrigger, plantName: due.item.name)
                .accessibilityLabel("Water \(due.item.name)")
                .accessibilityIdentifier("today-care-mark-done-\(due.item.id)")
            } else {
                Button {
                    onMarkDone()
                    slapOn = true
                    Task { try? await Task.sleep(for: .milliseconds(800)); slapOn = false }
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.bacanGreen)
                        .stickerSlap(isOn: slapOn, color: .bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Mark done")
                .accessibilityIdentifier("today-care-mark-done-\(due.item.id)")
            }
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

    @State private var slapOn = false

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
                Button {
                    store.send(.radarCareItemMarkedDone(itemID: careItemID, taskID: taskID))
                    slapOn = true
                    Task { try? await Task.sleep(for: .milliseconds(800)); slapOn = false }
                } label: {
                    let isPlant = item.category == .plant
                    Image(systemName: isPlant ? "drop.fill" : "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.bacanGreen)
                        .frame(width: 30, height: 30)
                        .stickerSlap(isOn: isPlant ? false : slapOn, color: .bacanGreen)
                        .leafUnfurl(isOn: isPlant ? slapOn : false, color: .bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(item.category == .plant ? "Water" : "Mark done")
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
