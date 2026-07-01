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

/// A shared family calendar event. Ported from Fambo's `FamboEvent`, trimmed to Menere's needs
/// (dropped: email/photo/share sources, confidence, drafts, EventKit mirroring, child-visibility).
///
/// Persisted at `households/{hid}/events/{id}`.
public struct FamilyEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    public var recurrence: RecurrenceOption
    /// `HouseholdMember.id`s (uids) this event involves.
    public var assigneeIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        recurrence: RecurrenceOption = .none,
        assigneeIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.recurrence = recurrence
        self.assigneeIDs = assigneeIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
        recurrence = try c.decodeIfPresent(RecurrenceOption.self, forKey: .recurrence) ?? .none
        assigneeIDs = try c.decodeIfPresent([String].self, forKey: .assigneeIDs) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
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
