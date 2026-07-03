import Foundation
import FamilyDomain

/// Read-only tools: today's snapshot, calendar, brain search, meal plan, lists, house status, money,
/// care. All are best-effort — a failed fetch degrades to an empty/explanatory result, never a throw.
func queryTools(_ ctx: AgentContext, _ d: AgentDeps) -> [BasicAgentTool] {
    let hid = ctx.hid
    let p = d.persistence

    // MARK: get_today_snapshot
    let todaySnapshot = BasicAgentTool(
        name: "get_today_snapshot",
        description: "Today at a glance: events today, tonight's dinner, chores due, home-care due, documents needing attention, and which smart-home ecosystems are set up. Call this first for open-ended 'what's going on' questions.",
        inputSchema: .object([:])
    ) { _ in
        async let events = try? p.events(hid)
        async let chores = try? p.chores(hid)
        async let care = try? p.careItems(hid)
        async let docs = try? p.documents(hid)
        async let plan = try? p.mealPlan(hid)
        let evs = (await events) ?? []
        let chs = (await chores) ?? []
        let careItems = (await care) ?? []
        let documents = (await docs) ?? []
        let meals = (await plan) ?? []

        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
        let todaysEvents = evs
            .flatMap { ev in ev.occurrences(from: start, to: end, calendar: cal).map { (ev, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { AgentValue.string("\($0.0.title) at \(AgentDates.human($0.1, allDay: $0.0.isAllDay))") }

        let dinner = meals.first { cal.isDateInToday($0.date) }
        let dinnerText: AgentValue = dinner.map { .string($0.isEatingOut ? ($0.restaurantName ?? "eating out") : $0.recipeTitle) } ?? .null

        let dueChores = chs.filter { !$0.isCompleted && choreBucket($0) != nil }
            .map { AgentValue.string($0.title) }
        let careDue = CareItem.dueTasks(in: careItems)
            .map { AgentValue.string("\($0.item.name): \($0.task.title)\($0.isOverdue ? " (overdue)" : "")") }
        let attn = documents.filter { $0.needsAttention(now: Date(), within: 30) }
            .map { AgentValue.string($0.title) }

        async let hue = try? p.hueConfig(hid)
        async let lutron = try? p.lutronConfig(hid)
        async let sonos = try? p.sonosConfig(hid)
        async let nest = try? p.nestConfig(hid)
        async let hubspace = try? p.hubspaceConfig(hid)
        async let meross = try? p.merossConfig(hid)
        var ecosystems: [String] = []
        if let c = (await hue) ?? nil, !c.bridges.isEmpty { ecosystems.append("lights") }
        if ((await lutron) ?? nil) != nil { ecosystems.append("shades") }
        if ((await sonos) ?? nil) != nil { ecosystems.append("sonos") }
        if let c = (await nest) ?? nil, c.isConnected { ecosystems.append("thermostat") }
        if let c = (await hubspace) ?? nil, c.isConnected { ecosystems.append("water") }
        if let c = (await meross) ?? nil, c.isConnected { ecosystems.append("garage") }

        return AgentToolResult(content: AgentJSON.object([
            "eventsToday": .array(todaysEvents),
            "dinnerTonight": dinnerText,
            "choresDue": .array(dueChores),
            "careDue": .array(careDue),
            "documentsNeedingAttention": .array(attn),
            "house": ecosystems.isEmpty ? .null : .array(ecosystems.map(AgentValue.string)),
        ]))
    }

    // MARK: query_calendar(from, to)
    let queryCalendar = BasicAgentTool(
        name: "query_calendar",
        description: "List calendar events (with recurrence expanded) between two dates. Dates are ISO-8601 or yyyy-MM-dd.",
        inputSchema: .object([
            "from": .string("Start of the window (ISO-8601 or yyyy-MM-dd)."),
            "to": .string("End of the window (ISO-8601 or yyyy-MM-dd)."),
        ], required: ["from", "to"])
    ) { input in
        guard let fromS = input.string("from"), let from = AgentDates.parse(fromS),
              let toS = input.string("to"), let to = AgentDates.parse(toS) else {
            return AgentToolResult(content: "Please give a from and to date (ISO-8601 or yyyy-MM-dd).")
        }
        let events = (try? await p.events(hid)) ?? []
        let cal = Calendar.current
        let occ = events
            .flatMap { ev in ev.occurrences(from: from, to: to, calendar: cal).map { (ev, $0) } }
            .sorted { $0.1 < $1.1 }
            .map { pair -> AgentValue in
                var o: [String: AgentValue] = [
                    "title": .string(pair.0.title),
                    "when": .string(AgentDates.human(pair.1, allDay: pair.0.isAllDay)),
                ]
                if let loc = pair.0.location, !loc.isEmpty { o["location"] = .string(loc) }
                return .object(o)
            }
        return AgentToolResult(content: AgentJSON.object(["events": .array(occ), "count": .int(occ.count)]))
    }

    // MARK: search_brain(query)
    let searchBrain = BasicAgentTool(
        name: "search_brain",
        description: "Search the family document 'brain' (receipts, medical, school, manuals, …) by keyword. Returns matching documents newest-first.",
        inputSchema: .object([
            "query": .string("Keywords to search for."),
        ], required: ["query"])
    ) { input in
        let query = input.string("query") ?? ""
        let docs = (try? await p.documents(hid)) ?? []
        let hits = BrainRanking.results(documents: docs, query: query, type: nil).prefix(10).map { doc -> AgentValue in
            var o: [String: AgentValue] = ["title": .string(doc.title), "type": .string(doc.type.rawValue)]
            if let s = doc.summary, !s.isEmpty { o["summary"] = .string(s) }
            if let v = doc.vendor, !v.isEmpty { o["vendor"] = .string(v) }
            return .object(o)
        }
        return AgentToolResult(content: AgentJSON.object(["results": .array(Array(hits)), "count": .int(hits.count)]))
    }

    // MARK: get_meal_plan(weekOffset)
    let getMealPlan = BasicAgentTool(
        name: "get_meal_plan",
        description: "The dinner plan for a week. weekOffset 0 = this week, 1 = next week, -1 = last week.",
        inputSchema: .object([
            "weekOffset": .integer("Weeks from the current week (default 0)."),
        ])
    ) { input in
        let offset = input.int("weekOffset") ?? 0
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.date(byAdding: .day, value: offset * 7, to: cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today) ?? today
        let weekEnd = cal.date(byAdding: .day, value: 7, to: weekStart) ?? today
        let plan = (try? await p.mealPlan(hid)) ?? []
        let entries = plan
            .filter { $0.date >= weekStart && $0.date < weekEnd }
            .sorted { $0.date < $1.date }
            .map { e -> AgentValue in
                .object([
                    "date": .string(AgentDates.human(e.date, allDay: true)),
                    "meal": .string(e.isEatingOut ? (e.restaurantName ?? "eating out") : e.recipeTitle),
                ])
            }
        return AgentToolResult(content: AgentJSON.object(["week": .array(entries), "count": .int(entries.count)]))
    }

    // MARK: get_lists
    let getLists = BasicAgentTool(
        name: "get_lists",
        description: "All shared family lists by name, with open/total item counts.",
        inputSchema: .object([:])
    ) { _ in
        let lists = (try? await p.lists(hid)) ?? []
        var out: [AgentValue] = []
        for list in lists {
            let items = (try? await p.listItems(hid, list.id)) ?? []
            let open = items.filter { !$0.isCompleted }.count
            out.append(.object([
                "name": .string(list.title),
                "open": .int(open),
                "total": .int(items.count),
            ]))
        }
        return AgentToolResult(content: AgentJSON.object(["lists": .array(out), "count": .int(out.count)]))
    }

    // MARK: get_list_items(listName)
    let getListItems = BasicAgentTool(
        name: "get_list_items",
        description: "The items on a named list (open items first).",
        inputSchema: .object([
            "listName": .string("Which list."),
        ], required: ["listName"])
    ) { input in
        let name = input.string("listName") ?? ""
        let lists = (try? await p.lists(hid)) ?? []
        switch Fuzzy.resolve(name, in: lists, name: { $0.title }) {
        case let .matched(list):
            let items = (try? await p.listItems(hid, list.id)) ?? []
            let sorted = items.sorted { !$0.isCompleted && $1.isCompleted }
            let out = sorted.map { AgentValue.object(["item": .string($0.title), "done": .bool($0.isCompleted)]) }
            return AgentToolResult(content: AgentJSON.object(["list": .string(list.title), "items": .array(out)]))
        case let .ambiguous(matches):
            return AgentToolResult(content: Fuzzy.disambiguation(matches.map(\.title)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(name, available: lists.map(\.title)))
        }
    }

    // MARK: get_house_status
    let getHouseStatus = BasicAgentTool(
        name: "get_house_status",
        description: "Best-effort current state of the smart home per ecosystem: lights, shades, sonos, thermostat, water spigots, garage.",
        inputSchema: .object([:])
    ) { _ in
        var sections: [String: AgentValue] = [:]

        if let cfg = (try? await p.hueConfig(hid)) ?? nil, !cfg.bridges.isEmpty {
            let snaps = await d.hue.readHouse(cfg.bridges)
            let onRooms = snaps.flatMap(\.rooms).filter(\.anyOn).map { AgentValue.string($0.name) }
            sections["lights"] = .object(["roomsOn": .array(onRooms)])
        }
        if let cfg = (try? await p.lutronConfig(hid)) ?? nil, let shades = try? await d.lutron.shades(cfg) {
            let lines = shades.map { AgentValue.string("\($0.name): \($0.level)% open") }
            sections["shades"] = .array(lines)
        }
        let sonosCfg: SonosConfig? = (try? await p.sonosConfig(hid)) ?? nil
        if let speakers = try? await d.sonos.discover(sonosCfg), !speakers.isEmpty {
            sections["sonos"] = .array(speakers.map { AgentValue.string($0.name) })
        }
        if let cfg = (try? await p.nestConfig(hid)) ?? nil, cfg.isConnected, let thermos = try? await d.nest.thermostats(cfg) {
            let lines = thermos.map { t -> AgentValue in
                .object([
                    "room": .string(t.roomName),
                    "mode": .string(t.mode.label),
                    "ambientF": t.ambientF.map { .double($0.rounded()) } ?? .null,
                ])
            }
            sections["thermostat"] = .array(lines)
        }
        if let cfg = (try? await p.hubspaceConfig(hid)) ?? nil, cfg.isConnected, let spigots = try? await d.hubspace.spigots(cfg) {
            let lines = spigots.flatMap { s in s.outlets.map { AgentValue.string("\($0.name): \($0.isOpen ? "open" : "closed")") } }
            sections["water"] = .array(lines)
        }
        if let cfg = (try? await p.merossConfig(hid)) ?? nil, cfg.isConnected, let doors = try? await d.meross.garageState(cfg) {
            let lines = doors.map { AgentValue.string("\($0.displayName): \($0.statusLine)") }
            sections["garage"] = .array(lines)
        }

        if sections.isEmpty {
            return AgentToolResult(content: "No smart-home ecosystems are set up yet.")
        }
        return AgentToolResult(content: AgentJSON.object(sections))
    }

    // MARK: get_money_month(monthOffset)
    let getMoneyMonth = BasicAgentTool(
        name: "get_money_month",
        description: "Spending for a month by category vs budget. monthOffset 0 = this month, -1 = last month.",
        inputSchema: .object([
            "monthOffset": .integer("Months from the current month (default 0)."),
        ])
    ) { input in
        let offset = input.int("monthOffset") ?? 0
        let month = MoneyRollup.shiftMonth(Date(), by: offset)
        async let exp = try? p.expenses(hid)
        async let budgets = try? p.budgetConfig(hid)
        let summary = MoneyRollup.summary(expenses: (await exp) ?? [], budgets: (await budgets) ?? nil, month: month)
        let lines = summary.lines.map { line -> AgentValue in
            var o: [String: AgentValue] = [
                "category": .string(line.category.displayName),
                "spent": .double((line.spent * 100).rounded() / 100),
            ]
            if let limit = line.limit { o["budget"] = .double(limit); o["overBudget"] = .bool(line.isOverBudget) }
            return .object(o)
        }
        return AgentToolResult(content: AgentJSON.object([
            "month": .string(AgentDates.human(summary.monthStart, allDay: true)),
            "total": .double((summary.total * 100).rounded() / 100),
            "categories": .array(lines),
        ]))
    }

    // MARK: get_care_due
    let getCareDue = BasicAgentTool(
        name: "get_care_due",
        description: "Home-care tasks (plants, pets, house zones) due soon or overdue.",
        inputSchema: .object([:])
    ) { _ in
        let items = (try? await p.careItems(hid)) ?? []
        let due = CareItem.dueTasks(in: items).map { d -> AgentValue in
            .object([
                "item": .string(d.item.name),
                "task": .string(d.task.title),
                "days": .int(d.days),
                "overdue": .bool(d.isOverdue),
            ])
        }
        return AgentToolResult(content: AgentJSON.object(["due": .array(due), "count": .int(due.count)]))
    }

    return [
        todaySnapshot, queryCalendar, searchBrain, getMealPlan, getLists,
        getListItems, getHouseStatus, getMoneyMonth, getCareDue,
    ]
}

/// Chore "today board" bucket: 0 overdue · 1 today · 2 undated · nil future.
func choreBucket(_ c: Chore, now: Date = Date()) -> Int? {
    let cal = Calendar.current
    let startOfToday = cal.startOfDay(for: now)
    guard let due = c.dueDate else { return 2 }
    let endOfToday = cal.date(byAdding: .day, value: 1, to: startOfToday)!
    if due < startOfToday { return 0 }
    if due < endOfToday { return 1 }
    return nil
}
