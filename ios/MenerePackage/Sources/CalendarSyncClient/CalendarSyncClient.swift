import Dependencies
import DependenciesMacros
import FamilyDomain
import Foundation

/// A device calendar the user can toggle for import, grouped by account in the sync-settings sheet.
public struct DeviceCalendar: Codable, Equatable, Identifiable, Sendable {
    public var id: String            // EKCalendar.calendarIdentifier
    public var title: String
    public var accountName: String   // EKSource.title (e.g. "iCloud", "Gmail")
    public var colorHex: String

    public init(id: String, title: String, accountName: String, colorHex: String) {
        self.id = id
        self.title = title
        self.accountName = accountName
        self.colorHex = colorHex
    }
}

/// One materialized EventKit occurrence in a fetch window. Recurring Apple events yield MANY of these
/// (one per instance), each with a distinct `dedupKey` — the fix for Fambo's series-collapse bug where
/// every instance shared a single `eventIdentifier`.
public struct ImportedEvent: Equatable, Sendable {
    /// `"<EKEvent.eventIdentifier>#<ISO8601 occurrence-start>"`. Stable across syncs for a given
    /// occurrence, and unique per occurrence within a series.
    public var dedupKey: String
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?

    public init(
        dedupKey: String,
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.dedupKey = dedupKey
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }
}

/// Coarse EventKit authorization state (maps `EKAuthorizationStatus`).
public enum CalendarAuthStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// EventKit wrapper for two-way Apple Calendar sync (P2.1). Ported and improved from Fambo's
/// `CalendarClient`. A `@DependencyClient` so features inject it and tests swap in mocks.
///
/// Loop prevention: `fetchWindow` excludes the "Bacán" push calendar, and pushed events land ONLY in
/// that calendar — so our own pushes never re-import.
@DependencyClient
public struct CalendarSyncClient: Sendable {
    /// Prompt for full calendar access (`requestFullAccessToEvents`). Returns whether granted.
    public var requestAccess: @Sendable () async throws -> Bool = { false }
    /// Current authorization status without prompting.
    public var authorizationStatus: @Sendable () -> CalendarAuthStatus = { .notDetermined }
    /// All writable event calendars on the device, for the account-grouped picker.
    public var availableCalendars: @Sendable () async throws -> [DeviceCalendar] = { [] }
    /// Fetch every occurrence in `[start, end]`, EXCLUDING the Bacán calendar (id passed so we never
    /// re-import our own pushes) and honoring the enabled set (nil = all calendars). Recurring events
    /// are expanded to one `ImportedEvent` per instance.
    public var fetchWindow: @Sendable (
        _ start: Date, _ end: Date, _ bacanCalendarID: String?, _ enabledCalendarIDs: Set<String>?
    ) async throws -> [ImportedEvent] = { _, _, _, _ in [] }
    /// Create (idempotently) the dedicated "Bacán" calendar. Prefers `knownID` when it still exists,
    /// else an existing calendar titled "Bacán", else creates one. Returns its `calendarIdentifier`.
    public var ensureBacanCalendar: @Sendable (_ knownID: String?) async throws -> String = { _ in "" }
    /// Push or update `event` into the target calendar (default: Bacán). Maps `RecurrenceOption` →
    /// `EKRecurrenceRule` so recurring Bacán events become true recurring Apple events (ONE EKEvent +
    /// rule). Returns the `EKEvent.eventIdentifier`.
    ///
    /// No-resurrection: if the event already has an identifier but the EKEvent was deleted on the Apple
    /// side, this is a no-op that returns the same (now-dangling) identifier — the deleted copy is not
    /// recreated.
    public var saveEvent: @Sendable (_ event: FamilyEvent, _ targetCalendarID: String?) async throws -> String = { _, _ in "" }
    /// Delete the EKEvent with `eventIdentifier` (span `.futureEvents` for recurring series).
    public var deleteEvent: @Sendable (_ eventIdentifier: String) async throws -> Void
    /// Whether an EKEvent with `eventIdentifier` currently exists (used by tests / diagnostics).
    public var eventExists: @Sendable (_ eventIdentifier: String) -> Bool = { _ in false }
}

extension CalendarSyncClient: TestDependencyKey {
    public static let testValue = CalendarSyncClient()
    public static let previewValue = CalendarSyncClient(
        requestAccess: { true },
        authorizationStatus: { .granted },
        availableCalendars: {
            [
                DeviceCalendar(id: "home", title: "Home", accountName: "iCloud", colorHex: "#34C759"),
                DeviceCalendar(id: "work", title: "Work", accountName: "Gmail", colorHex: "#007AFF"),
            ]
        },
        fetchWindow: { _, _, _, _ in [] },
        ensureBacanCalendar: { _ in "bacan-cal" },
        saveEvent: { _, _ in UUID().uuidString },
        deleteEvent: { _ in },
        eventExists: { _ in true }
    )
}

public extension DependencyValues {
    var calendarSyncClient: CalendarSyncClient {
        get { self[CalendarSyncClient.self] }
        set { self[CalendarSyncClient.self] = newValue }
    }
}

// MARK: - Dedup key

public enum CalendarSyncKey {
    /// A fixed UTC ISO8601 formatter (no fractional seconds) for stable dedup keys across syncs.
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `"<eventIdentifier>#<ISO8601 occurrence-start>"`. For non-recurring events the occurrence start
    /// equals the event start, so the key is still unique and stable.
    public static func dedupKey(eventIdentifier: String, occurrenceStart: Date) -> String {
        "\(eventIdentifier)#\(isoFormatter.string(from: occurrenceStart))"
    }
}
