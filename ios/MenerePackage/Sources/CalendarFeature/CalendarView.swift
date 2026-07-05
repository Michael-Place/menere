import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI

public struct CalendarView: View {
    @Bindable var store: StoreOf<CalendarReducer>
    private let cal = Calendar.current

    public init(store: StoreOf<CalendarReducer>) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            monthHeader
            weekdayHeader
            monthGrid
            Divider()
            agenda
        }
        .background(Color.familyCanvas)
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.syncSettingsTapped) } label: {
                    Image(systemName: store.isSyncing ? "arrow.triangle.2.circlepath" : "calendar.badge.clock")
                        .symbolEffect(.rotate, isActive: store.isSyncing)
                }
                .accessibilityLabel("Calendar sync")
                .accessibilityIdentifier("calendar-sync-button")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: { Image(systemName: "plus") }
                    .accessibilityIdentifier("add-event-button")
            }
        }
        .task { store.send(.task) }
        .sheet(item: $store.scope(state: \.form, action: \.form)) { formStore in
            EventFormView(store: formStore)
        }
        .sheet(item: $store.scope(state: \.syncSettings, action: \.syncSettings)) { syncStore in
            CalendarSyncSettingsView(store: syncStore)
        }
    }

    // MARK: Header

    private var monthHeader: some View {
        HStack {
            Button { store.send(.shiftMonth(-1)) } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(monthTitle(store.visibleMonth))
                .font(.headline)
                .foregroundStyle(Color.ink)
            Spacer()
            Button { store.send(.shiftMonth(1)) } label: { Image(systemName: "chevron.right") }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .tint(.bacanGreen)
    }

    private var weekdayHeader: some View {
        HStack {
            ForEach(cal.veryShortWeekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Month grid

    private var monthGrid: some View {
        let days = gridDays(for: store.visibleMonth)
        let datesWithEvents = daysWithEvents(in: days)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
            ForEach(days, id: \.self) { day in
                dayCell(day, inMonth: cal.isDate(day, equalTo: store.visibleMonth, toGranularity: .month),
                        hasEvent: datesWithEvents.contains(cal.startOfDay(for: day)))
            }
        }
        .padding(8)
    }

    private func dayCell(_ day: Date, inMonth: Bool, hasEvent: Bool) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDate)
        let isToday = cal.isDateInToday(day)
        return Button {
            store.send(.selectDate(day))
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout)
                    .fontWeight(isToday ? .bold : .regular)
                    .foregroundStyle(inMonth ? (isSelected ? .white : Color.ink) : Color.inkSoft.opacity(0.5))
                Circle()
                    .fill(hasEvent ? (isSelected ? Color.white : Color.bacanGreen) : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.bacanGreen : (isToday ? Color.bacanGreen.opacity(0.12) : .clear))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Agenda

    private var agenda: some View {
        let items = occurrences(on: store.selectedDate)
        return Group {
            if items.isEmpty {
                VStack {
                    Spacer()
                    Text("Nothing on the books — a rare quiet day.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.inkSoft)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(items) { item in
                        Button { store.send(.editTapped(item.event)) } label: {
                            agendaRow(item)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.familyCanvas)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.familyCanvas)
            }
        }
    }

    private func agendaRow(_ item: EventOccurrence) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.event.title).foregroundStyle(Color.ink)
                    // Imported-from-Apple events wear a small ink-soft Apple glyph.
                    if item.event.resolvedSource == .calendarImport {
                        Image(systemName: "applelogo")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.inkSoft)
                            .accessibilityLabel("From Apple Calendar")
                    }
                }
                Text(item.event.isAllDay ? "All day" : timeString(item.date))
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
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
                    .overlay(Circle().stroke(Color.familyCanvas, lineWidth: 1.5))
            }
        }
    }

    // MARK: Occurrence helpers

    /// Materialized occurrences on a single day, sorted by time.
    private func occurrences(on day: Date) -> [EventOccurrence] {
        let start = cal.startOfDay(for: day)
        let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        return store.events
            .flatMap { event in
                event.occurrences(from: start, to: end, calendar: cal).map { EventOccurrence(event: event, date: $0) }
            }
            .sorted { $0.date < $1.date }
    }

    /// The set of day-starts (within the visible grid) that have at least one occurrence.
    private func daysWithEvents(in days: [Date]) -> Set<Date> {
        guard let first = days.first, let last = days.last else { return [] }
        let from = cal.startOfDay(for: first)
        let to = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: last))!.addingTimeInterval(-1)
        var result: Set<Date> = []
        for event in store.events {
            for date in event.occurrences(from: from, to: to, calendar: cal) {
                result.insert(cal.startOfDay(for: date))
            }
        }
        return result
    }

    /// The 42 grid dates (6 weeks) covering the month containing `month`.
    private func gridDays(for month: Date) -> [Date] {
        guard let monthInterval = cal.dateInterval(of: .month, for: month),
              let firstWeek = cal.dateInterval(of: .weekOfMonth, for: monthInterval.start)
        else { return [] }
        var days: [Date] = []
        var cursor = firstWeek.start
        for _ in 0..<42 {
            days.append(cursor)
            cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
        }
        return days
    }

    private func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        return f.string(from: date)
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
