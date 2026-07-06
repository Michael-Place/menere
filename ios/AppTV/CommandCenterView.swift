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

// MARK: - Time of day

/// Reads the device clock to shape the command center's mood — a warm morning greeting that leans
/// on today's plan, versus a calmer evening that celebrates the leaderboard. Kept deliberately
/// subtle: it changes the greeting, a one-line tagline, which cards lead, and which card glows.
enum TimeOfDay {
    case morning, afternoon, evening, night

    static var current: TimeOfDay {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return .morning
        case 12..<17: return .afternoon
        case 17..<22: return .evening
        default: return .night
        }
    }

    /// Evening + night wind the room down — calmer copy, leaderboard gets the spotlight.
    var isWindingDown: Bool { self == .evening || self == .night }

    /// The big headline greeting. `family` is already fallback-safe ("your family").
    func headline(family: String) -> String {
        switch self {
        case .morning:   return "Good morning, \(family) 🌅"
        case .afternoon: return "Good afternoon, \(family) ☀️"
        case .evening:   return "Winding down 🌙"
        case .night:     return "Good night 🌙"
        }
    }

    /// A quieter second line under the headline.
    func tagline(family: String) -> String {
        switch self {
        case .morning:   return "Here's your day at a glance."
        case .afternoon: return "Here's what's still ahead today."
        case .evening:   return "\(family)'s evening — here's where things landed."
        case .night:     return "The house is settling in. See you in the morning."
        }
    }

    /// Time-aware leaderboard title.
    var leaderboardTitle: String { isWindingDown ? "Tonight's leaders" : "Chores leaderboard" }
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

    /// The clear chores champion, if there is one: the top member must have earned XP *and* be
    /// strictly ahead of second place (or be the only one on the board). A tie → no crown, no
    /// confetti (celebrating everyone equally would just be noise).
    var champion: LeaderRow? {
        guard let top = leaders.first, top.xp > 0 else { return nil }
        if leaders.count == 1 { return top }
        return top.xp > leaders[1].xp ? top : nil
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

    /// Bumped once per appearance when a clear champion is present → fires a single confetti burst.
    @State private var confettiBurst = 0
    /// Tracks the champion across a session so a *change* of leader re-fires the celebration.
    @State private var celebratedChampionID: String?

    private let tod = TimeOfDay.current

    init(summary: PairingModel.HouseholdSummary, onExit: @escaping () -> Void) {
        self.summary = summary
        self.onExit = onExit
        _model = State(initialValue: CommandCenterModel(hid: summary.hid))
    }

    var body: some View {
        // The content is the PRIMARY view so it inherits tvOS's built-in title-safe area (the
        // gradient/confetti are demoted to `.background`/`.overlay`, so they can't collapse the
        // content's safe insets — which was pulling the header off the top of the panel). A little
        // hand padding adds breathing room inside the safe rect.
        VStack(alignment: .leading, spacing: 28) {
            header

            HStack(alignment: .top, spacing: 36) {
                // Time-aware emphasis: mornings lead with the plan (schedule on top);
                // evenings wind down and hand the spotlight to the leaderboard.
                VStack(spacing: 24) {
                    if tod.isWindingDown {
                        briefingCard
                        dinnerCard
                        scheduleCard
                    } else {
                        scheduleCard
                        dinnerCard
                        briefingCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)

                leaderboardCard
                    .frame(width: 700)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 80)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [CC.cream, CC.creamDeep],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        // Big-screen joy: a one-shot confetti rain over everything when there's a champion.
        .overlay(
            ConfettiView(burst: confettiBurst)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        )
        .task {
            await model.load()
            celebrateIfLeader()
        }
        .onChange(of: model.champion?.id) { _, _ in celebrateIfLeader() }
    }

    /// Fires the celebration when a clear champion appears — and again if the leader changes mid-
    /// session (a live re-read could flip the crown). Never fires for a tie or an empty board.
    private func celebrateIfLeader() {
        guard let champ = model.champion else { celebratedChampionID = nil; return }
        guard champ.id != celebratedChampionID else { return }
        celebratedChampionID = champ.id
        confettiBurst += 1
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text(tod.headline(family: summary.familyName))
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .foregroundStyle(CC.green)
                Text(tod.tagline(family: summary.familyName))
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .foregroundStyle(CC.ink.opacity(0.55))
                Text(dateLine)
                    .font(.system(.title3, design: .rounded).weight(.medium))
                    .foregroundStyle(CC.ink.opacity(0.4))
            }
            Spacer()
            Button(action: onExit) {
                Label("Ambient", systemImage: "photo.on.rectangle.angled")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
            }
            .focused($exitFocused)
        }
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
        CommandCard(icon: "calendar", accent: CC.sky, title: "Today's schedule",
                    emphasized: !tod.isWindingDown) {
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
        CommandCard(icon: "trophy.fill", accent: CC.marigold, title: tod.leaderboardTitle,
                    emphasized: tod.isWindingDown) {
            if !model.leaders.isEmpty {
                // Scrolls (focusable) once the family grows past what fits — degrades gracefully.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 18) {
                        ForEach(Array(model.leaders.enumerated()), id: \.element.id) { idx, row in
                            LeaderboardRow(
                                rank: idx + 1,
                                row: row,
                                isChampion: row.id == model.champion?.id
                            )
                        }
                    }
                }
                .frame(maxHeight: 720)
                .focusable(model.leaders.count > 5)
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
    var emphasized: Bool = false
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
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(CC.card)
                // The time-of-day emphasis: a subtly stronger lift + a whisper-thin accent ring.
                .shadow(color: .black.opacity(emphasized ? 0.16 : 0.10),
                        radius: emphasized ? 26 : 18, y: emphasized ? 14 : 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(accent.opacity(emphasized ? 0.55 : 0), lineWidth: 3)
        )
        .animation(.easeInOut(duration: 0.5), value: emphasized)
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
    var isChampion: Bool = false

    /// A soft breathing glow for the reigning champion — celebratory but never frantic.
    @State private var glow = false

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

            // Avatar chip — the champion wears a little crown.
            Image(systemName: row.avatar)
                .font(.system(size: 40))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Circle().fill(color))
                .overlay(alignment: .topTrailing) {
                    if isChampion {
                        Text("👑")
                            .font(.system(size: 46))
                            .rotationEffect(.degrees(18))
                            .offset(x: 20, y: -34)
                            .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    }
                }

            // Name + level.
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(CC.ink)
                Text(isChampion ? "Level \(row.level) · leading! 🎉" : "Level \(row.level)")
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
                .fill(rank == 1 ? color.opacity(isChampion ? 0.20 : 0.14) : CC.cream.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(color.opacity(isChampion ? (glow ? 0.85 : 0.35) : 0),
                              lineWidth: isChampion ? 4 : 0)
        )
        .shadow(color: isChampion ? color.opacity(glow ? 0.45 : 0.18) : .clear,
                radius: isChampion ? (glow ? 26 : 14) : 0)
        .scaleEffect(isChampion && glow ? 1.015 : 1.0)
        .onAppear {
            guard isChampion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
    }
}

// MARK: - Confetti

/// A tasteful, one-shot confetti rain. Increment `burst` to fire it — a fresh cohort of paper bits
/// drifts down and fades. It clears itself after the fall, so it never loops or nags: pure moment.
private struct ConfettiView: View {
    let burst: Int

    @State private var pieces: [Piece] = []

    struct Piece: Identifiable {
        let id = UUID()
        let x: CGFloat            // 0…1 across the width
        let color: Color
        let size: CGFloat
        let spin: Double
        let delay: Double
        let duration: Double
        let isCircle: Bool
    }

    private static let palette: [Color] = [CC.marigold, CC.terracotta, CC.sky, CC.green]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                ForEach(pieces) { piece in
                    ConfettiPieceView(piece: piece, screen: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onChange(of: burst) { _, newValue in
            guard newValue > 0 else { return }
            fire()
        }
    }

    private func fire() {
        var fresh: [Piece] = []
        for _ in 0..<80 {
            fresh.append(Piece(
                x: .random(in: 0...1),
                color: Self.palette.randomElement()!,
                size: .random(in: 16...30),
                spin: .random(in: 180...900),
                delay: .random(in: 0...0.6),
                duration: .random(in: 2.2...3.4),
                isCircle: Bool.random()
            ))
        }
        pieces = fresh
        // Tidy up after the longest piece has finished its fall.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            pieces.removeAll()
        }
    }
}

private struct ConfettiPieceView: View {
    let piece: ConfettiView.Piece
    let screen: CGSize

    @State private var fall = false

    var body: some View {
        Group {
            if piece.isCircle {
                Circle().fill(piece.color)
            } else {
                RoundedRectangle(cornerRadius: 4).fill(piece.color)
            }
        }
        .frame(width: piece.size, height: piece.size * (piece.isCircle ? 1 : 0.6))
        .rotationEffect(.degrees(fall ? piece.spin : 0))
        .position(x: piece.x * screen.width, y: fall ? screen.height + 60 : -60)
        .opacity(fall ? 0 : 1)
        .onAppear {
            withAnimation(.easeIn(duration: piece.duration).delay(piece.delay)) {
                fall = true
            }
        }
    }
}
