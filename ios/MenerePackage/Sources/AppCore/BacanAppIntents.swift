import AppIntents
import Dependencies
import FamilyDomain
import FirebaseAuth
import FirebaseCore
import Foundation
import PersistenceClient

// MARK: - Act V (V5-Siri) — App Intents + Shortcuts (the "open front door", voice/Spotlight vector)
//
// A first set of App Intents that drive the family's core verbs from Siri / Shortcuts / Spotlight
// WITHOUT needing the app open first. Two intents run fully HEADLESS (`openAppWhenRun == false`):
// they configure Firebase in the intent process if needed, use the persisted Firebase Auth session
// (restored from the shared keychain access group) to resolve the household, and read/write via the
// same `PersistenceClient` path the UI uses:
//   • AddToGroceriesIntent — append an item to the family grocery list.
//   • WhatsDueTodayIntent  — speak the Family Radar (overdue renewals + overdue care).
// Two intents deep-link into the app (`openAppWhenRun == true`) via `IntentRouter`:
//   • LogMemoryIntent  — jump to the memory editor.
//   • CaptureIntent    — open the Bacán capture/assistant surface.
//
// Everything lives in AppCore so it can reach `PersistenceClient` + `FamilyDomain` directly; the
// `AppShortcutsProvider` (BacanShortcuts) exposes them with natural phrases. App Intents (not legacy
// SiriKit) need NO Siri entitlement.

// MARK: - Firebase / auth bootstrap inside the intent process

/// App Intents can run in a freshly-launched (or background-launched) app process. Firebase is
/// normally configured by `AppDelegate`, but guard against a race / prewarm where `perform()` runs
/// before that — configure once, on main, only if nobody has yet.
enum IntentFirebase {
    static func ensureConfigured() async {
        if FirebaseApp.app() == nil {
            await MainActor.run {
                if FirebaseApp.app() == nil { FirebaseApp.configure() }
            }
        }
    }
}

/// Thrown when a headless intent can't authenticate — the user hasn't signed in on this device yet.
/// Surfaces as a friendly spoken line telling them to open Bacán once.
enum IntentAuthError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:
            return "Open Bacán and sign in once, then I can do that from here."
        }
    }
}

/// The resolved backend context for a headless intent: the signed-in uid, the household id, and a
/// live `PersistenceClient`. Built by `resolve()`, which configures Firebase, reads the persisted
/// auth session, and resolves the household — the same `ensureHousehold` path the app uses.
struct IntentContext {
    let uid: String
    let hid: String
    let persistence: PersistenceClient

    static func resolve() async throws -> IntentContext {
        await IntentFirebase.ensureConfigured()
        guard let uid = Auth.auth().currentUser?.uid else {
            throw IntentAuthError.notSignedIn
        }
        @Dependency(\.persistence) var persistence
        let hid = try await persistence.ensureHousehold(uid)
        return IntentContext(uid: uid, hid: hid, persistence: persistence)
    }
}

// MARK: - Deep-link routing (open-app intents → in-app navigation)

/// Where an open-app intent wants the app to land once it foregrounds.
public enum IntentDestination: Equatable, Sendable {
    case logMemory   // → Memories tab, memory editor open
    case capture     // → the Bacán capture / assistant surface
}

/// A tiny process-shared mailbox the open-app intents write and `MainTabView` drains on foreground.
/// App-based (non-extension) intents run in the app's own process — when the app is cold-launched to
/// run the intent, this static lives in that same process, so the pending destination survives to the
/// first `MainTabView` appearance. Thread-safe via a lock (perform() may run off the main actor).
public final class IntentRouter: @unchecked Sendable {
    public static let shared = IntentRouter()

    private let lock = NSLock()
    private var _pending: IntentDestination?

    private init() {}

    public var pending: IntentDestination? {
        get { lock.lock(); defer { lock.unlock() }; return _pending }
        set { lock.lock(); defer { lock.unlock() }; _pending = newValue }
    }

    /// Atomically read-and-clear the pending destination (so it fires exactly once).
    public func consume() -> IntentDestination? {
        lock.lock(); defer { lock.unlock() }
        let p = _pending
        _pending = nil
        return p
    }
}

// MARK: - AddToGroceriesIntent (HEADLESS)

/// "Add milk to groceries in Bacán." Appends an item to the family's grocery list — resolving the
/// list (find-or-create) and writing headless via `PersistenceClient`. No app open required.
struct AddToGroceriesIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Groceries"
    static let description = IntentDescription(
        "Add an item to your family's grocery list in Bacán — hands-free.",
        categoryName: "Lists"
    )
    /// Headless: the system runs this in the background; no UI.
    static let openAppWhenRun = false

    @Parameter(title: "Item", requestValueDialog: "What should I add to the groceries?")
    var item: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to groceries")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .result(dialog: IntentDialog(stringLiteral: "I didn't catch what to add — try again?"))
        }
        let ctx = try await IntentContext.resolve()

        // Resolve the grocery list (find the existing one, else create a fresh grocery list).
        let lists = try await ctx.persistence.lists(ctx.hid)
        let list: FamilyList
        if let existing = lists.first(where: { $0.isGrocery }) {
            list = existing
        } else {
            let created = FamilyList(title: "Groceries", icon: "cart", listType: .grocery)
            try await ctx.persistence.saveList(ctx.hid, created)
            list = created
        }

        // Append after the current items so it lands at the bottom, like a manual add.
        let existingItems = try await ctx.persistence.listItems(ctx.hid, list.id)
        let sortOrder = (existingItems.map(\.sortOrder).max() ?? -1) + 1
        let newItem = ListItem(title: name, listID: list.id, sortOrder: sortOrder)
        try await ctx.persistence.saveListItem(ctx.hid, newItem)

        return .result(dialog: IntentDialog(stringLiteral: "Added \(name) to Groceries."))
    }
}

// MARK: - WhatsDueTodayIntent (HEADLESS)

/// "What's due in Bacán today?" Reads the Family Radar (expired renewals + overdue care) and speaks
/// a warm, first-name summary. No app open required.
struct WhatsDueTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due Today"
    static let description = IntentDescription(
        "Hear what needs the family's attention — overdue renewals and care.",
        categoryName: "Today"
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let ctx = try await IntentContext.resolve()

        async let docsTask = ctx.persistence.documents(ctx.hid)
        async let careTask = ctx.persistence.careItems(ctx.hid)
        let documents = try await docsTask
        let careItems = try await careTask
        let pets = careItems.filter { $0.kind == .pet }

        let radar = FamilyRadar.compute(documents: documents, pets: pets, careItems: careItems)
        let summary = WhatsDueSummary.make(radar: radar)
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

/// Composes the spoken "what's due" line from the pure `FamilyRadar`. Warm + witty, first names —
/// e.g. "Fajita's rabies is overdue and the Japanese maple needs water. Coming up: Kindercare
/// registration in 8 days."
enum WhatsDueSummary {
    static func make(radar: FamilyRadar) -> String {
        if radar.isEmpty {
            return "Nothing's overdue — the family's all caught up. Bacán!"
        }

        var loud: [String] = []
        // Expired document renewals (the loudest signal) — "Fajita's rabies is overdue".
        for item in radar.expired.prefix(3) {
            loud.append("\(item.label) is overdue")
        }
        // Overdue care rows (already humanized: "6 plants need water", "Sprinkle: heartworm", "HVAC filter").
        for care in radar.care.prefix(3) {
            let label = care.label
            if label.lowercased().contains("water") {
                loud.append(label)                       // "6 plants need water" reads well as-is
            } else {
                loud.append("\(label) is overdue")
            }
        }

        var soon: [String] = []
        for item in radar.upcoming.prefix(2) {
            if item.days == 0 {
                soon.append("\(item.label) is due today")
            } else {
                soon.append("\(item.label) in \(item.days) day\(item.days == 1 ? "" : "s")")
            }
        }

        var sentence = ""
        if !loud.isEmpty {
            sentence = capitalizingFirst(joinNaturally(loud)) + "."
        }
        if !soon.isEmpty {
            let prefix = sentence.isEmpty ? "" : " "
            sentence += "\(prefix)Coming up: \(joinNaturally(soon))."
        }
        return sentence.isEmpty ? "You've got a few things on the radar — open Bacán for the details." : sentence
    }

    /// "a" → "a"; "a, b" → "a and b"; "a, b, c" → "a, b, and c".
    static func joinNaturally(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default:
            let head = parts.dropLast().joined(separator: ", ")
            return "\(head), and \(parts.last!)"
        }
    }

    static func capitalizingFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }
}

// MARK: - LogMemoryIntent (OPEN APP)

/// "Log a memory in Bacán." Opens the app and jumps straight to the memory editor.
struct LogMemoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Log a Memory"
    static let description = IntentDescription(
        "Open Bacán to the memory editor to capture a family moment.",
        categoryName: "Memories"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = .logMemory
        return .result()
    }
}

// MARK: - CaptureIntent (OPEN APP)

/// "Quick capture in Bacán." Opens the app to the Bacán capture / assistant surface so anything —
/// photo, note, receipt — can be dropped in and routed.
struct CaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Capture"
    static let description = IntentDescription(
        "Open Bacán to quickly capture and file anything.",
        categoryName: "Capture"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.shared.pending = .capture
        return .result()
    }
}

// MARK: - AppShortcutsProvider

/// Exposes the intents to Shortcuts / Spotlight / Siri with natural phrases. The `\(.applicationName)`
/// token resolves to Bacán (see `CFBundleSpokenName` in Info.plist). Discovered automatically by the
/// system once the app is built + launched.
public struct BacanShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddToGroceriesIntent(),
            // NOTE: a `String` parameter can't be embedded in an App Shortcut phrase (only AppEntity/
            // AppEnum can) — so the item is prompted at run time via `requestValueDialog` instead.
            phrases: [
                "Add to groceries in \(.applicationName)",
                "Add a grocery item in \(.applicationName)",
                "Add to my \(.applicationName) grocery list",
                "Add something to \(.applicationName) groceries"
            ],
            shortTitle: "Add to Groceries",
            systemImageName: "cart.badge.plus"
        )
        AppShortcut(
            intent: WhatsDueTodayIntent(),
            phrases: [
                "What's due in \(.applicationName) today",
                "What's due in \(.applicationName)",
                "What needs attention in \(.applicationName)",
                "Ask \(.applicationName) what's due"
            ],
            shortTitle: "What's Due Today",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: LogMemoryIntent(),
            phrases: [
                "Log a memory in \(.applicationName)",
                "Capture a memory in \(.applicationName)",
                "Add a memory to \(.applicationName)"
            ],
            shortTitle: "Log a Memory",
            systemImageName: "book.closed"
        )
        AppShortcut(
            intent: CaptureIntent(),
            phrases: [
                "Quick capture in \(.applicationName)",
                "Capture something in \(.applicationName)",
                "New capture in \(.applicationName)"
            ],
            shortTitle: "Quick Capture",
            systemImageName: "sparkles"
        )
    }
}
