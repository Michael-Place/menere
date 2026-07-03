import Dependencies
import EventKit
import FamilyDomain
import Foundation
import UIKit

// MARK: - RecurrenceOption → EventKit

public extension RecurrenceOption {
    /// The EventKit `(frequency, interval)` for this option, or nil for `.none`. Exposed for unit
    /// testing the mapping without constructing a live `EKRecurrenceRule`.
    var ekFrequencyAndInterval: (frequency: EKRecurrenceFrequency, interval: Int)? {
        switch self {
        case .none: nil
        case .daily: (.daily, 1)
        case .weekly: (.weekly, 1)
        case .biweekly: (.weekly, 2)   // biweekly = weekly, interval 2
        case .monthly: (.monthly, 1)
        case .yearly: (.yearly, 1)
        }
    }

    /// A concrete open-ended `EKRecurrenceRule` for pushing a recurring Bacán event as a true recurring
    /// Apple event (fixes Fambo's flaw #3 — it pushed each event as a single non-recurring EKEvent).
    var ekRecurrenceRule: EKRecurrenceRule? {
        guard let (frequency, interval) = ekFrequencyAndInterval else { return nil }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: nil)
    }
}

// MARK: - Live implementation

extension CalendarSyncClient: DependencyKey {
    public static let liveValue: CalendarSyncClient = {
        // A single shared store, guarded by a serial actor so concurrent sync phases don't race it.
        let coordinator = EKCoordinator()

        return CalendarSyncClient(
            requestAccess: { try await coordinator.requestAccess() },
            authorizationStatus: {
                switch EKEventStore.authorizationStatus(for: .event) {
                case .fullAccess, .authorized: .granted
                case .denied, .restricted, .writeOnly: .denied
                case .notDetermined: .notDetermined
                @unknown default: .notDetermined
                }
            },
            availableCalendars: { await coordinator.availableCalendars() },
            fetchWindow: { start, end, bacanID, enabled in
                await coordinator.fetchWindow(start: start, end: end, bacanCalendarID: bacanID, enabledCalendarIDs: enabled)
            },
            ensureBacanCalendar: { knownID in try await coordinator.ensureBacanCalendar(knownID: knownID) },
            saveEvent: { event, targetID in try await coordinator.saveEvent(event, targetCalendarID: targetID) },
            deleteEvent: { id in try await coordinator.deleteEvent(identifier: id) },
            eventExists: { id in EKEventStore().event(withIdentifier: id) != nil }
        )
    }()
}

/// Serializes access to the shared `EKEventStore` (a cleaner replacement for Fambo's
/// `nonisolated(unsafe)` free variable).
private actor EKCoordinator {
    private let store = EKEventStore()

    /// The dedicated push calendar's title.
    static let bacanTitle = "Bacán"

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func availableCalendars() -> [DeviceCalendar] {
        store.calendars(for: .event).map { cal in
            let cgColor = cal.cgColor ?? UIColor.systemGray.cgColor
            let comps = cgColor.components ?? [0, 0, 0]
            let hex = String(
                format: "#%02X%02X%02X",
                Int((comps.count > 0 ? comps[0] : 0) * 255),
                Int((comps.count > 1 ? comps[1] : 0) * 255),
                Int((comps.count > 2 ? comps[2] : 0) * 255)
            )
            return DeviceCalendar(
                id: cal.calendarIdentifier,
                title: cal.title,
                accountName: cal.source?.title ?? "Other",
                colorHex: hex
            )
        }
    }

    func fetchWindow(
        start: Date, end: Date, bacanCalendarID: String?, enabledCalendarIDs: Set<String>?
    ) -> [ImportedEvent] {
        var calendars = store.calendars(for: .event)
        // Exclude the Bacán calendar — never re-import our own pushes (loop prevention).
        if let bacanID = bacanCalendarID {
            calendars = calendars.filter { $0.calendarIdentifier != bacanID }
        }
        // Also exclude any stray calendar literally titled "Bacán" (belt-and-suspenders if the stored
        // id drifted).
        calendars = calendars.filter { $0.title != Self.bacanTitle }
        if let enabled = enabledCalendarIDs {
            calendars = calendars.filter { enabled.contains($0.calendarIdentifier) }
        }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        // `events(matching:)` already expands recurring events into per-occurrence EKEvents — each shares
        // the series `eventIdentifier` but has its own `startDate`, which is exactly the dedup dimension.
        return store.events(matching: predicate).map { ek in
            ImportedEvent(
                dedupKey: CalendarSyncKey.dedupKey(
                    eventIdentifier: ek.eventIdentifier ?? UUID().uuidString,
                    occurrenceStart: ek.startDate
                ),
                title: ek.title ?? "Untitled",
                startDate: ek.startDate,
                endDate: ek.endDate,
                isAllDay: ek.isAllDay,
                location: ek.location,
                notes: ek.notes
            )
        }
    }

    func ensureBacanCalendar(knownID: String?) throws -> String {
        // 1. Prefer the stored identifier if it still resolves (Fambo fix — don't rely on the title).
        if let knownID,
           let existing = store.calendar(withIdentifier: knownID),
           existing.allowsContentModifications {
            return existing.calendarIdentifier
        }
        // 2. Fall back to an existing calendar titled "Bacán".
        if let byTitle = store.calendars(for: .event).first(where: { $0.title == Self.bacanTitle }) {
            return byTitle.calendarIdentifier
        }
        // 3. Create it.
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.bacanTitle
        let sources = store.sources
        if let iCloud = sources.first(where: { $0.sourceType == .calDAV }) {
            calendar.source = iCloud
        } else if let local = sources.first(where: { $0.sourceType == .local }) {
            calendar.source = local
        } else if let first = sources.first {
            calendar.source = first
        } else if let defaultCal = store.defaultCalendarForNewEvents {
            calendar.source = defaultCal.source
        }
        try store.saveCalendar(calendar, commit: true)
        return calendar.calendarIdentifier
    }

    func saveEvent(_ event: FamilyEvent, targetCalendarID: String?) throws -> String {
        let ekEvent: EKEvent
        if let identifier = event.eventKitIdentifier {
            if let existing = store.event(withIdentifier: identifier) {
                ekEvent = existing
            } else {
                // No-resurrection: the Apple copy was deleted — don't recreate it.
                return identifier
            }
        } else {
            ekEvent = EKEvent(eventStore: store)
            if let targetCalendarID, let cal = store.calendar(withIdentifier: targetCalendarID) {
                ekEvent.calendar = cal
            } else if let bacan = store.calendars(for: .event).first(where: { $0.title == Self.bacanTitle }) {
                ekEvent.calendar = bacan
            } else {
                ekEvent.calendar = store.defaultCalendarForNewEvents
            }
        }

        ekEvent.title = event.title
        ekEvent.startDate = event.startDate
        ekEvent.endDate = event.endDate ?? event.startDate.addingTimeInterval(3600)
        ekEvent.isAllDay = event.isAllDay
        ekEvent.location = event.location
        ekEvent.notes = event.notes

        // Recurrence: replace any existing rules, then apply the mapped rule (or leave non-recurring).
        for rule in ekEvent.recurrenceRules ?? [] { ekEvent.removeRecurrenceRule(rule) }
        if let rule = event.recurrence.ekRecurrenceRule {
            ekEvent.addRecurrenceRule(rule)
        }

        // futureEvents so edits to a recurring Bacán event propagate across the whole series.
        let span: EKSpan = event.recurrence == .none ? .thisEvent : .futureEvents
        try store.save(ekEvent, span: span, commit: true)
        return ekEvent.eventIdentifier
    }

    func deleteEvent(identifier: String) throws {
        guard let ekEvent = store.event(withIdentifier: identifier) else { return }
        let span: EKSpan = (ekEvent.recurrenceRules?.isEmpty == false) ? .futureEvents : .thisEvent
        try store.remove(ekEvent, span: span, commit: true)
    }
}
