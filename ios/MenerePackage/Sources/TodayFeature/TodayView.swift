import ComposableArchitecture
import FamilyDomain
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

                // ─── SEAM (P6-C3): AI "briefing" card slots in HERE, above the schedule. ───

                scheduleCard
                dinnerCard
                quickActions

                // ─── SEAM (P6-C2): family member cards + "chores due today" card slot in HERE. ───
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
            if let title = tonightsDinnerTitle {
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

    private var tonightsDinnerTitle: String? {
        let entry = store.mealPlan.first { cal.isDateInToday($0.date) }
        guard let entry else { return nil }
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
