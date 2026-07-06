import FirebaseFirestore
import Foundation
import Observation
import SwiftUI

// MARK: - Palette (tvOS-local ¡Bacán! identity tokens)

/// The living-room command center's warm cream/green palette. Defined locally so the tvOS target
/// stays free of the iOS-only `MenereUI` — same shades as the family-four `MemberColor` tokens.
enum CC {
    static let cream = Color(red: 0.98, green: 0.96, blue: 0.90)
    static let creamDeep = Color(red: 0.94, green: 0.91, blue: 0.83)
    static let green = Color(red: 0.18, green: 0.43, blue: 0.31)     // bacanGreen
    static let terracotta = Color(red: 0.75, green: 0.35, blue: 0.24)
    static let marigold = Color(red: 0.89, green: 0.63, blue: 0.18)
    static let sky = Color(red: 0.31, green: 0.58, blue: 0.78)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.16)
    static let card = Color.white

    /// A SwiftUI `Color` for a member's chosen palette color, straight off `MemberColor.rgb`.
    static func color(for member: MemberColor) -> Color {
        let c = member.rgb
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

// MARK: - Model

/// Reads everything the command center shows — all one-shot Firestore reads, no callables.
///
/// Sources (all under `households/{hid}/…`):
/// - `briefings/{ET-today}` → `summary` + `highlights[]` (written by the `generateDailyBriefing` fn).
/// - `events` → filtered to today's occurrences, sorted by start time.
/// - `mealPlan` → today's entry (recipe title or restaurant), recipe resolved from `recipes/{id}`.
/// - `memberStats` + `members` → the chores leaderboard (XP + level per member).
@MainActor
@Observable
final class CommandCenterModel {
    struct ScheduleItem: Identifiable, Equatable {
        let id: String
        let title: String
        let timeLabel: String
        let isAllDay: Bool
        let sortKey: Date
    }

    struct DinnerInfo: Equatable {
        let title: String
        let subtitle: String?   // "Eating out" / servings / etc.
        let isEatingOut: Bool
    }

    struct LeaderRow: Identifiable, Equatable {
        let id: String
        let name: String
        let color: MemberColor
        let avatar: String
        let xp: Int
        let level: Int
        let chores: Int
    }

    private(set) var isLoading = true
    private(set) var briefing: String?
    private(set) var highlights: [String] = []
    private(set) var schedule: [ScheduleItem] = []
    private(set) var dinner: DinnerInfo?
    private(set) var leaders: [LeaderRow] = []

    private let hid: String
    private let db = Firestore.firestore()

    /// The family lives on Eastern time; "today" (and the briefing doc id) are computed in ET so the
    /// TV agrees with the phone app and the server-written briefing.
    private static let etZone = TimeZone(identifier: "America/New_York") ?? .current
    private static var etCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = etZone
        return c
    }()

    init(hid: String) { self.hid = hid }

    func load() async {
        isLoading = true
        async let brief: Void = loadBriefing()
        async let sched: Void = loadSchedule()
        async let din: Void = loadDinner()
        async let board: Void = loadLeaderboard()
        _ = await (brief, sched, din, board)
        isLoading = false
    }

    private var household: DocumentReference { db.collection("households").document(hid) }

    // MARK: Briefing

    private func loadBriefing() async {
        let f = DateFormatter()
        f.timeZone = Self.etZone
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard let snap = try? await household.collection("briefings").document(today).getDocument(),
              let data = snap.data() else { return }
        let summary = (data["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        briefing = (summary?.isEmpty == false) ? summary : nil
        highlights = (data["highlights"] as? [String])?.filter { !$0.isEmpty } ?? []
    }

    // MARK: Schedule

    private func loadSchedule() async {
        guard let docs = try? await household.collection("events").getDocuments() else { return }
        let now = Date()
        let cal = Self.etCalendar
        let timeFmt = DateFormatter()
        timeFmt.timeZone = Self.etZone
        timeFmt.dateFormat = "h:mm a"

        var items: [ScheduleItem] = []
        for doc in docs.documents {
            let data = doc.data()
            guard let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else { continue }
            guard let start = Self.date(data["startDate"]) else { continue }
            guard cal.isDate(start, inSameDayAs: now) else { continue }
            let isAllDay = data["isAllDay"] as? Bool ?? false
            items.append(ScheduleItem(
                id: doc.documentID,
                title: title,
                timeLabel: isAllDay ? "All day" : timeFmt.string(from: start),
                isAllDay: isAllDay,
                sortKey: start
            ))
        }
        // All-day first (they sort to midnight), then chronological.
        schedule = items.sorted {
            if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
            return $0.sortKey < $1.sortKey
        }
    }

    // MARK: Dinner

    private func loadDinner() async {
        guard let docs = try? await household.collection("mealPlan").getDocuments() else { return }
        let now = Date()
        let cal = Self.etCalendar
        var todayEntry: [String: Any]?
        for doc in docs.documents {
            let data = doc.data()
            guard let date = Self.date(data["date"]) else { continue }
            if cal.isDate(date, inSameDayAs: now) { todayEntry = data; break }
        }
        guard let data = todayEntry else { return }

        if let restaurant = (data["restaurantName"] as? String)?.trimmingCharacters(in: .whitespaces),
           !restaurant.isEmpty {
            dinner = DinnerInfo(title: restaurant, subtitle: "Eating out", isEatingOut: true)
            return
        }
        var title = (data["recipeTitle"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if title.isEmpty, let rid = data["recipeID"] as? String, !rid.isEmpty {
            if let recipe = try? await household.collection("recipes").document(rid).getDocument(),
               let name = recipe.data()?["title"] as? String {
                title = name.trimmingCharacters(in: .whitespaces)
            }
        }
        if !title.isEmpty {
            dinner = DinnerInfo(title: title, subtitle: nil, isEatingOut: false)
        }
    }

    // MARK: Leaderboard

    private func loadLeaderboard() async {
        async let membersDocs = household.collection("members").getDocuments()
        async let statsDocs = household.collection("memberStats").getDocuments()

        guard let members = try? await membersDocs else { return }
        let stats = (try? await statsDocs)?.documents ?? []

        // memberID → (xp, level, chores)
        var statByMember: [String: (xp: Int, level: Int, chores: Int)] = [:]
        for doc in stats {
            let data = doc.data()
            let mid = (data["memberID"] as? String) ?? doc.documentID
            statByMember[mid] = (
                xp: Self.int(data["totalXP"]),
                level: max(1, Self.int(data["level"], default: 1)),
                chores: Self.int(data["choresCompleted"])
            )
        }

        var rows: [LeaderRow] = []
        for doc in members.documents {
            let data = doc.data()
            let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? "Someone"
            let colorRaw = data["color"] as? String ?? "botanical"
            let color = MemberColor(rawValue: colorRaw) ?? .botanical
            let avatar = data["avatarSystemName"] as? String ?? "person.circle.fill"
            let s = statByMember[doc.documentID]
            rows.append(LeaderRow(
                id: doc.documentID,
                name: name,
                color: color,
                avatar: avatar,
                xp: s?.xp ?? 0,
                level: s?.level ?? 1,
                chores: s?.chores ?? 0
            ))
        }
        leaders = rows.sorted { ($0.xp, $1.name) > ($1.xp, $0.name) }
    }

    // MARK: Helpers

    /// Firestore stores dates as `Timestamp`; tolerate a raw `Date` too (cache paths).
    private static func date(_ any: Any?) -> Date? {
        if let ts = any as? Timestamp { return ts.dateValue() }
        if let d = any as? Date { return d }
        return nil
    }

    private static func int(_ any: Any?, default def: Int = 0) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return def
    }
}

// MARK: - View

/// The living-room command center: a "what's going on today" board built for the big screen —
/// greeting + AI briefing, today's schedule, tonight's dinner, and the gamified chores leaderboard.
struct CommandCenterView: View {
    let summary: PairingModel.HouseholdSummary
    var onExit: () -> Void

    @State private var model: CommandCenterModel
    @FocusState private var exitFocused: Bool

    init(summary: PairingModel.HouseholdSummary, onExit: @escaping () -> Void) {
        self.summary = summary
        self.onExit = onExit
        _model = State(initialValue: CommandCenterModel(hid: summary.hid))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [CC.cream, CC.creamDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 32) {
                header

                HStack(alignment: .top, spacing: 36) {
                    VStack(spacing: 26) {
                        briefingCard
                        scheduleCard
                        dinnerCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    leaderboardCard
                        .frame(width: 700)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(56)
        }
        .task { await model.load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(greeting)
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(CC.green)
                Text(dateLine)
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .foregroundStyle(CC.ink.opacity(0.6))
            }
            Spacer()
            Button(action: onExit) {
                Label("Ambient", systemImage: "photo.on.rectangle.angled")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            .focused($exitFocused)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let word = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        return "\(word), \(summary.familyName)"
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    // MARK: Cards

    private var briefingCard: some View {
        CommandCard(icon: "sparkles", accent: CC.marigold, title: "Today's briefing") {
            if let briefing = model.briefing {
                VStack(alignment: .leading, spacing: 18) {
                    Text(briefing)
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundStyle(CC.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.highlights.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.highlights.enumerated()), id: \.offset) { _, h in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("•").foregroundStyle(CC.marigold)
                                    Text(h)
                                }
                                .font(.system(.title3, design: .rounded))
                                .foregroundStyle(CC.ink.opacity(0.8))
                            }
                        }
                    }
                }
            } else if model.isLoading {
                loadingLine
            } else {
                EmptyLine(text: "No briefing yet today — enjoy the quiet.")
            }
        }
    }

    private var scheduleCard: some View {
        CommandCard(icon: "calendar", accent: CC.sky, title: "Today's schedule") {
            if !model.schedule.isEmpty {
                VStack(spacing: 14) {
                    ForEach(model.schedule.prefix(6)) { item in
                        HStack(spacing: 20) {
                            Text(item.timeLabel)
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(CC.sky)
                                .frame(width: 190, alignment: .leading)
                            Text(item.title)
                                .font(.system(.title3, design: .rounded))
                                .foregroundStyle(CC.ink)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    if model.schedule.count > 6 {
                        HStack {
                            Text("+ \(model.schedule.count - 6) more")
                                .font(.system(.title3, design: .rounded).weight(.medium))
                                .foregroundStyle(CC.ink.opacity(0.5))
                            Spacer()
                        }
                    }
                }
            } else if model.isLoading {
                loadingLine
            } else {
                EmptyLine(text: "Nothing on the calendar today. 🌤️")
            }
        }
    }

    private var dinnerCard: some View {
        CommandCard(icon: "fork.knife", accent: CC.terracotta, title: "Tonight's dinner") {
            if let dinner = model.dinner {
                HStack(spacing: 18) {
                    Text(dinner.isEatingOut ? "🍽️" : "🍲").font(.system(size: 52))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dinner.title)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(CC.ink)
                        if let sub = dinner.subtitle {
                            Text(sub)
                                .font(.system(.title3, design: .rounded))
                                .foregroundStyle(CC.terracotta)
                        }
                    }
                    Spacer()
                }
            } else if model.isLoading {
                loadingLine
            } else {
                EmptyLine(text: "No dinner planned yet — chef's choice! 👩‍🍳")
            }
        }
    }

    private var leaderboardCard: some View {
        CommandCard(icon: "trophy.fill", accent: CC.marigold, title: "Chores leaderboard") {
            if !model.leaders.isEmpty {
                VStack(spacing: 18) {
                    ForEach(Array(model.leaders.enumerated()), id: \.element.id) { idx, row in
                        LeaderboardRow(rank: idx + 1, row: row)
                    }
                }
            } else if model.isLoading {
                loadingLine
            } else {
                EmptyLine(text: "No stars yet — knock out a chore to lead the board!")
            }
        }
    }

    private var loadingLine: some View {
        HStack(spacing: 16) {
            ProgressView().tint(CC.green)
            Text("Loading…")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(CC.ink.opacity(0.5))
        }
    }
}

// MARK: - Card chrome

private struct CommandCard<Content: View>: View {
    let icon: String
    let accent: Color
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(CC.ink)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 36)
                .fill(CC.card)
                .shadow(color: .black.opacity(0.10), radius: 18, y: 10)
        )
    }
}

private struct EmptyLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(.title2, design: .rounded).weight(.medium))
            .foregroundStyle(CC.ink.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Leaderboard row

private struct LeaderboardRow: View {
    let rank: Int
    let row: CommandCenterModel.LeaderRow

    private var medal: String? {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return nil
        }
    }

    var body: some View {
        let color = CC.color(for: row.color)
        HStack(spacing: 22) {
            // Rank / medal.
            ZStack {
                if let medal {
                    Text(medal).font(.system(size: 48))
                } else {
                    Text("\(rank)")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(CC.ink.opacity(0.4))
                }
            }
            .frame(width: 64)

            // Avatar chip.
            Image(systemName: row.avatar)
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(color))

            // Name + level.
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(CC.ink)
                Text("Level \(row.level)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(color)
            }
            Spacer()

            // XP badge.
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(row.xp)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                Text("XP")
                    .font(.system(.headline, design: .rounded).weight(.bold))
                    .foregroundStyle(CC.ink.opacity(0.4))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 22)
        .background(
            RoundedRectangle(cornerRadius: 26)
                .fill(rank == 1 ? color.opacity(0.14) : CC.cream.opacity(0.6))
        )
    }
}
