import Foundation
import FamilyDomain
import PersistenceClient

/// Family-data actions: add events, manage lists, complete chores/care the canonical way (activity +
/// server XP), log expenses, set dinner. The acting `uid` is the actor for activity/XP credit.
func familyTools(_ ctx: AgentContext, _ d: AgentDeps) -> [BasicAgentTool] {
    let hid = ctx.hid
    let uid = ctx.uid
    let p = d.persistence

    // MARK: add_event
    let addEvent = BasicAgentTool(
        name: "add_event",
        description: "Add a calendar event. Times are ISO-8601 (or yyyy-MM-dd for all-day).",
        inputSchema: .object([
            "title": .string("Event title."),
            "startISO": .string("Start time (ISO-8601 or yyyy-MM-dd)."),
            "endISO": .string("Optional end time (ISO-8601)."),
            "allDay": .boolean("All-day event (default false)."),
            "location": .string("Optional location."),
            "notes": .string("Optional notes."),
        ], required: ["title", "startISO"])
    ) { input in
        guard let title = input.string("title"),
              let startS = input.string("startISO"), let start = AgentDates.parse(startS) else {
            return AgentToolResult(content: "Need a title and a start time.")
        }
        let end = input.string("endISO").flatMap(AgentDates.parse)
        let allDay = input.bool("allDay") ?? false
        let event = FamilyEvent(
            title: title, startDate: start, endDate: end, isAllDay: allDay,
            location: input.string("location"), notes: input.string("notes"), source: .manual
        )
        do {
            try await p.saveEvent(hid, event)
            try? await p.logActivity(hid, ActivityItem.eventAdded(title: title, actorID: uid))
            return AgentToolResult(
                content: AgentJSON.object(["added": .bool(true), "title": .string(title), "when": .string(AgentDates.human(start, allDay: allDay))]),
                receipt: AgentReceipt(icon: "calendar.badge.plus", line: "Added “\(title)”")
            )
        } catch {
            return AgentToolResult(content: "Couldn't add the event: \(error.localizedDescription)")
        }
    }

    // MARK: add_to_list
    let addToList = BasicAgentTool(
        name: "add_to_list",
        description: "Add an item to a named shared list.",
        inputSchema: .object([
            "listName": .string("Which list."),
            "item": .string("The item to add."),
        ], required: ["listName", "item"])
    ) { input in
        let listName = input.string("listName") ?? ""
        guard let item = input.string("item") else { return AgentToolResult(content: "What should I add?") }
        let lists = (try? await p.lists(hid)) ?? []
        switch Fuzzy.resolve(listName, in: lists, name: { $0.title }) {
        case let .matched(list):
            let existing = (try? await p.listItems(hid, list.id)) ?? []
            let newItem = ListItem(title: item, listID: list.id, sortOrder: existing.count)
            do {
                try await p.saveListItem(hid, newItem)
                return AgentToolResult(
                    content: AgentJSON.object(["added": .string(item), "toList": .string(list.title)]),
                    receipt: AgentReceipt(icon: "plus.circle", line: "Added “\(item)” to \(list.title)")
                )
            } catch {
                return AgentToolResult(content: "Couldn't add to \(list.title): \(error.localizedDescription)")
            }
        case let .ambiguous(matches):
            return AgentToolResult(content: Fuzzy.disambiguation(matches.map(\.title)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(listName, available: lists.map(\.title)))
        }
    }

    // MARK: check_off_list_item
    let checkOff = BasicAgentTool(
        name: "check_off_list_item",
        description: "Check off (complete) an item on a named list.",
        inputSchema: .object([
            "listName": .string("Which list."),
            "item": .string("Which item to check off."),
        ], required: ["listName", "item"])
    ) { input in
        let listName = input.string("listName") ?? ""
        let itemName = input.string("item") ?? ""
        let lists = (try? await p.lists(hid)) ?? []
        guard case let .matched(list) = Fuzzy.resolve(listName, in: lists, name: { $0.title }) else {
            switch Fuzzy.resolve(listName, in: lists, name: { $0.title }) {
            case let .ambiguous(m): return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.title)))
            default: return AgentToolResult(content: Fuzzy.noMatch(listName, available: lists.map(\.title)))
            }
        }
        let items = ((try? await p.listItems(hid, list.id)) ?? []).filter { !$0.isCompleted }
        switch Fuzzy.resolve(itemName, in: items, name: { $0.title }) {
        case let .matched(item):
            var updated = item
            updated.isCompleted = true
            do {
                try await p.saveListItem(hid, updated)
                try? await p.logActivity(hid, ActivityItem.listItemChecked(title: item.title, list: list.title, actorID: uid))
                return AgentToolResult(
                    content: AgentJSON.object(["checkedOff": .string(item.title), "onList": .string(list.title)]),
                    receipt: AgentReceipt(icon: "checkmark.circle.fill", line: "Checked off “\(item.title)”")
                )
            } catch {
                return AgentToolResult(content: "Couldn't check it off: \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.title)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(itemName, available: items.map(\.title)))
        }
    }

    // MARK: complete_chore
    let completeChore = BasicAgentTool(
        name: "complete_chore",
        description: "Mark a chore done. Credits the assignee (or you), awards XP, and logs it.",
        inputSchema: .object([
            "choreName": .string("Which chore."),
        ], required: ["choreName"])
    ) { input in
        let name = input.string("choreName") ?? ""
        let chores = ((try? await p.chores(hid)) ?? []).filter { !$0.isCompleted }
        switch Fuzzy.resolve(name, in: chores, name: { $0.title }) {
        case let .matched(chore):
            let members = (try? await p.members(hid)) ?? []
            let outcome = ChoreCompletion.complete(chore, fallbackCreditID: uid, members: members)
            do {
                try await p.writeCompletion(hid: hid, outcome)
                return AgentToolResult(
                    content: AgentJSON.object(["completed": .string(chore.title)]),
                    receipt: AgentReceipt(icon: "checkmark.seal.fill", line: "✓ \(chore.title)")
                )
            } catch {
                return AgentToolResult(content: "Couldn't complete it: \(error.localizedDescription)")
            }
        case let .ambiguous(m):
            return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.title)))
        case .none:
            return AgentToolResult(content: Fuzzy.noMatch(name, available: chores.map(\.title)))
        }
    }

    // MARK: mark_care_done
    let markCareDone = BasicAgentTool(
        name: "mark_care_done",
        description: "Mark a home-care task done (watered a plant, changed a filter, walked a dog). Matches the item by name or species.",
        inputSchema: .object([
            "itemName": .string("Which plant / pet / zone / house item (name or species, e.g. 'the monstera')."),
            "taskName": .string("Which task, if the item has several (e.g. 'water'). Optional."),
        ], required: ["itemName"])
    ) { input in
        let itemName = input.string("itemName") ?? ""
        let items = (try? await p.careItems(hid)) ?? []
        let match = Fuzzy.resolve(itemName, in: items, name: { $0.name }, aliases: { [$0.species, $0.speciesLatin, $0.breed].compactMap { $0 } })
        guard case let .matched(item) = match else {
            switch match {
            case let .ambiguous(m): return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.name)))
            default: return AgentToolResult(content: Fuzzy.noMatch(itemName, available: items.map(\.name)))
            }
        }
        // Resolve the task: explicit name → fuzzy; else the single task, else the soonest due.
        let task: CareTask?
        if let taskName = input.string("taskName") {
            switch Fuzzy.resolve(taskName, in: item.tasks, name: { $0.title }) {
            case let .matched(t): task = t
            case let .ambiguous(m): return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.title)))
            case .none: return AgentToolResult(content: Fuzzy.noMatch(taskName, available: item.tasks.map(\.title)))
            }
        } else if item.tasks.count == 1 {
            task = item.tasks.first
        } else {
            task = item.soonestDueTask() ?? item.tasks.first
        }
        guard let task,
              let members = try? await p.members(hid),
              let outcome = CareCompletion.markDone(item: item, taskID: task.id, byMemberID: uid, members: members)
        else {
            return AgentToolResult(content: "Couldn't find a task to mark done on \(item.name).")
        }
        do {
            try await p.writeCareDone(hid: hid, outcome)
            let verb = ActivityItem.careVerb(forTask: task.title)
            return AgentToolResult(
                content: AgentJSON.object(["done": .string(task.title), "on": .string(item.name)]),
                receipt: AgentReceipt(icon: item.iconSymbol, line: "✓ \(verb.capitalized) \(item.name)")
            )
        } catch {
            return AgentToolResult(content: "Couldn't mark it done: \(error.localizedDescription)")
        }
    }

    // MARK: log_expense
    let logExpense = BasicAgentTool(
        name: "log_expense",
        description: "Record an expense.",
        inputSchema: .object([
            "amount": .number("Amount in dollars."),
            "vendor": .string("Where it was spent. Optional."),
            "category": .string("One of: groceries, dining, kids, house, garden, pets, fun, other. Optional — inferred if omitted."),
            "notes": .string("Optional notes."),
        ], required: ["amount"])
    ) { input in
        guard let amount = input.double("amount"), amount > 0 else {
            return AgentToolResult(content: "Need a positive amount.")
        }
        let vendor = input.string("vendor")
        let notes = input.string("notes")
        let category: ExpenseCategory
        if let raw = input.string("category"), let c = ExpenseCategory(rawValue: raw.lowercased()) {
            category = c
        } else {
            category = ExpenseCategory.suggested(from: [vendor, notes, input.string("category")].compactMap { $0 })
        }
        let expense = Expense(amount: amount, vendor: vendor, category: category, memberId: uid, source: .manual, notes: notes)
        do {
            try await p.saveExpense(hid, expense)
            let amountStr = String(format: "$%.2f", amount)
            return AgentToolResult(
                content: AgentJSON.object(["logged": .double(amount), "category": .string(category.displayName)]),
                receipt: AgentReceipt(icon: "dollarsign.circle", line: "Logged \(amountStr) · \(category.displayName)")
            )
        } catch {
            return AgentToolResult(content: "Couldn't log the expense: \(error.localizedDescription)")
        }
    }

    // MARK: set_dinner
    let setDinner = BasicAgentTool(
        name: "set_dinner",
        description: "Set dinner for a day — either a recipe by name, or eating out at a named place. Date defaults to today (ISO-8601 or yyyy-MM-dd).",
        inputSchema: .object([
            "dateISO": .string("Which day (default today)."),
            "recipeName": .string("A recipe to cook. Optional."),
            "eatingOut": .string("A restaurant name (eating out). Optional."),
        ])
    ) { input in
        let date = input.string("dateISO").flatMap(AgentDates.parse) ?? Date()
        let cal = Calendar.current
        let existing = ((try? await p.mealPlan(hid)) ?? []).first { cal.isDate($0.date, inSameDayAs: date) }
        let id = existing?.id ?? UUID().uuidString

        let entry: MealPlanEntry
        let receiptLine: String
        if let out = input.string("eatingOut") {
            entry = MealPlanEntry(id: id, date: date, restaurantName: out)
            receiptLine = "Dinner: \(out)"
        } else if let recipeName = input.string("recipeName") {
            let recipes = (try? await p.recipes(hid)) ?? []
            switch Fuzzy.resolve(recipeName, in: recipes, name: { $0.title }) {
            case let .matched(recipe):
                entry = MealPlanEntry(id: id, date: date, recipeID: recipe.id, recipeTitle: recipe.title)
                receiptLine = "Dinner: \(recipe.title)"
            case let .ambiguous(m):
                return AgentToolResult(content: Fuzzy.disambiguation(m.map(\.title)))
            case .none:
                return AgentToolResult(content: Fuzzy.noMatch(recipeName, available: recipes.map(\.title)))
            }
        } else {
            return AgentToolResult(content: "Give me a recipe name or a place to eat out.")
        }
        do {
            try await p.saveMealPlanEntry(hid, entry)
            return AgentToolResult(
                content: AgentJSON.object(["dinner": .string(receiptLine), "date": .string(AgentDates.human(date, allDay: true))]),
                receipt: AgentReceipt(icon: "fork.knife", line: receiptLine)
            )
        } catch {
            return AgentToolResult(content: "Couldn't set dinner: \(error.localizedDescription)")
        }
    }

    return [addEvent, addToList, checkOff, completeChore, markCareDone, logExpense, setDinner]
}
