import Foundation

/// Per-user Apple Calendar (EventKit) two-way sync preferences.
/// Persisted at `users/{uid}/settings/calendarSync` (mirrors Fambo's `calendarSync` doc; a per-USER
/// setting rather than a household one, since each family member syncs their own device calendars).
///
/// Decode-safe: every field has a default so a partial / hand-written doc still resolves.
public struct CalendarSyncPrefs: Codable, Equatable, Sendable {
    /// Master switch. When false, sync is dormant even if setup completed (the "Disconnect"-friendly
    /// pause). Defaults true so first-run setup goes straight to syncing.
    public var enabled: Bool
    /// Opt-OUT list: EventKit calendar identifiers the user does NOT want imported. Absence = enabled,
    /// so brand-new calendars import by default (matches Fambo).
    public var disabledCalendarIDs: [String]
    /// Whether the warm first-run onboarding step (value line → permission → picker) has completed.
    public var hasCompletedSetup: Bool
    /// The `calendarIdentifier` of the "Bacán" push calendar once created. Stored so we prefer it over
    /// fragile title-matching (a Fambo flaw — a renamed calendar orphaned pushed events).
    public var bacanCalendarID: String?
    /// When the last successful sync finished (drives the "Last synced …" line in the sheet footer).
    public var lastSyncedAt: Date?
    /// The `[start, end]` window covered by the last sync, so month navigation only re-syncs when the
    /// newly-visible month falls outside it.
    public var lastSyncedWindowStart: Date?
    public var lastSyncedWindowEnd: Date?

    public init(
        enabled: Bool = true,
        disabledCalendarIDs: [String] = [],
        hasCompletedSetup: Bool = false,
        bacanCalendarID: String? = nil,
        lastSyncedAt: Date? = nil,
        lastSyncedWindowStart: Date? = nil,
        lastSyncedWindowEnd: Date? = nil
    ) {
        self.enabled = enabled
        self.disabledCalendarIDs = disabledCalendarIDs
        self.hasCompletedSetup = hasCompletedSetup
        self.bacanCalendarID = bacanCalendarID
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncedWindowStart = lastSyncedWindowStart
        self.lastSyncedWindowEnd = lastSyncedWindowEnd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        disabledCalendarIDs = try c.decodeIfPresent([String].self, forKey: .disabledCalendarIDs) ?? []
        hasCompletedSetup = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false
        bacanCalendarID = try c.decodeIfPresent(String.self, forKey: .bacanCalendarID)
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        lastSyncedWindowStart = try c.decodeIfPresent(Date.self, forKey: .lastSyncedWindowStart)
        lastSyncedWindowEnd = try c.decodeIfPresent(Date.self, forKey: .lastSyncedWindowEnd)
    }

    /// Whether `calendarID` should be imported (opt-out semantics).
    public func isEnabled(_ calendarID: String) -> Bool {
        !disabledCalendarIDs.contains(calendarID)
    }

    public mutating func setEnabled(_ calendarID: String, _ enabled: Bool) {
        if enabled {
            disabledCalendarIDs.removeAll { $0 == calendarID }
        } else if !disabledCalendarIDs.contains(calendarID) {
            disabledCalendarIDs.append(calendarID)
        }
    }

    /// True when the visible month's window `[start, end]` sits within the last-synced window, so no
    /// re-sync is needed on navigation.
    public func windowCovered(start: Date, end: Date) -> Bool {
        guard let ws = lastSyncedWindowStart, let we = lastSyncedWindowEnd else { return false }
        return ws <= start && we >= end
    }
}
