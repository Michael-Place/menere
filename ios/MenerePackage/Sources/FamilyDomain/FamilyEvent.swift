import Foundation

/// How often an event repeats. Client-side expansion (see `CalendarFeature`) materializes
/// occurrences for the visible range — there is no server-side recurrence job.
public enum RecurrenceOption: String, CaseIterable, Equatable, Sendable, Codable {
    case none, daily, weekly, biweekly, monthly, yearly

    public var displayName: String {
        switch self {
        case .none: "Does not repeat"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .biweekly: "Every 2 weeks"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    /// The `Calendar.Component` step and stride for advancing one occurrence, or nil if `.none`.
    public var step: (component: Calendar.Component, value: Int)? {
        switch self {
        case .none: nil
        case .daily: (.day, 1)
        case .weekly: (.weekOfYear, 1)
        case .biweekly: (.weekOfYear, 2)
        case .monthly: (.month, 1)
        case .yearly: (.year, 1)
        }
    }
}

/// Where a `FamilyEvent` originated. Drives the two-way EventKit sync (P2.1):
/// - `.manual` / `.email` events are PUSHED into the dedicated "Bacán" Apple calendar
///   (email-extracted events carry no `source` and decode as `manual`, so forwarded school
///   emails also appear on both parents' Apple calendars — the desired behavior).
/// - `.calendarImport` events came FROM Apple; they are never pushed back (loop prevention).
public enum EventSource: String, Codable, Sendable, Equatable {
    case manual
    case calendarImport = "calendar_import"
    case email
}

/// A shared family calendar event. Ported from Fambo's `FamboEvent`, trimmed to Menere's needs.
/// P2.1 re-added two decode-safe EventKit-sync fields (`eventKitIdentifier`, `source`).
///
/// Persisted at `households/{hid}/events/{id}`.
public struct FamilyEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?
    /// The Apple-Calendar-mirrored notes for imported events. **Managed exclusively by
    /// `CalendarSyncEngine`** (pulled from / diffed against EventKit) — do NOT surface this as a
    /// user-editable field or the two-way sync will churn. The family's own event notes live in
    /// ``familyNotes`` instead.
    public var notes: String?
    /// The family's OWN freeform notes on this event (Rich-Text C2), stored as a portable
    /// **Markdown `String`** (see `RichNoteEditor`). Kept separate from ``notes`` on purpose so rich
    /// markdown never leaks into the EventKit sync mirror. Decode-safe additive field (older events
    /// nil ⇒ no family note); plain-string legacy values render as unformatted.
    public var familyNotes: String?
    public var recurrence: RecurrenceOption
    /// `HouseholdMember.id`s (uids) this event involves.
    public var assigneeIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    // MARK: EventKit sync (P2.1) — both decode-safe (nil for pre-P2.1 events).

    /// Link back to the Apple EventKit item this event mirrors.
    /// - For imported events (`source == .calendarImport`): the **dedup key**
    ///   `"<EKEvent.eventIdentifier>#<ISO8601 occurrence-start>"` — recurring Apple events expand to
    ///   ONE `FamilyEvent` per occurrence, each with a distinct key (fixes Fambo's series-collapse bug).
    /// - For pushed events (`source == .manual` / `.email`): the plain `EKEvent.eventIdentifier` of the
    ///   copy we created in the "Bacán" calendar (nil until first push).
    public var eventKitIdentifier: String?
    /// Origin of the event; nil decodes as `.manual` (see `resolvedSource`).
    public var source: EventSource?

    /// The effective origin — nil `source` (legacy / email-Function events) resolves to `.manual`,
    /// so those events push into Apple Calendar.
    public var resolvedSource: EventSource { source ?? .manual }

    public init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        familyNotes: String? = nil,
        recurrence: RecurrenceOption = .none,
        assigneeIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        eventKitIdentifier: String? = nil,
        source: EventSource? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.familyNotes = familyNotes
        self.recurrence = recurrence
        self.assigneeIDs = assigneeIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.eventKitIdentifier = eventKitIdentifier
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        startDate = try c.decode(Date.self, forKey: .startDate)
        endDate = try c.decodeIfPresent(Date.self, forKey: .endDate)
        isAllDay = try c.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        location = try c.decodeIfPresent(String.self, forKey: .location)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        familyNotes = try c.decodeIfPresent(String.self, forKey: .familyNotes)
        recurrence = try c.decodeIfPresent(RecurrenceOption.self, forKey: .recurrence) ?? .none
        assigneeIDs = try c.decodeIfPresent([String].self, forKey: .assigneeIDs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        eventKitIdentifier = try c.decodeIfPresent(String.self, forKey: .eventKitIdentifier)
        // nil `source` (legacy events + email-Function-written events) resolves to `.manual`.
        source = try c.decodeIfPresent(EventSource.self, forKey: .source)
    }

    /// Materializes the occurrence start-dates of this event that fall within `[from, to]`.
    /// Non-recurring events yield at most their own `startDate`. Capped to avoid runaway loops.
    public func occurrences(from: Date, to: Date, calendar: Calendar = .current) -> [Date] {
        guard let step = recurrence.step else {
            return (startDate >= from && startDate <= to) ? [startDate] : []
        }
        var result: [Date] = []
        var cursor = startDate
        var guardCount = 0
        // Fast-forward isn't strictly necessary for a month window; cap iterations generously.
        while cursor <= to, guardCount < 1000 {
            if cursor >= from { result.append(cursor) }
            guard let next = calendar.date(byAdding: step.component, value: step.value, to: cursor) else { break }
            cursor = next
            guardCount += 1
        }
        return result
    }
}
