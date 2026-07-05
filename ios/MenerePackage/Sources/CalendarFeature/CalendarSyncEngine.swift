import CalendarSyncClient
import FamilyDomain
import Foundation

/// The pure, deterministic core of the two-way EventKit sync. Given the current Firestore events and
/// the freshly-fetched Apple occurrences for a window, it computes exactly what to write — with no side
/// effects — so the three phases are unit-testable in isolation.
///
/// Three phases (Fambo's shape, with its three flaws fixed):
///   1. **Import** Apple → Bacán: new occurrences become individual `FamilyEvent`s
///      (`source: .calendarImport`, `recurrence: .none`, `eventKitIdentifier: <dedupKey>`). Recurring
///      Apple events expand to one row per instance (fixes flaw #1 — series collapse).
///   2. **Update** edited imports: diff title/start/end/isAllDay/location/notes and refresh the copy
///      (fixes flaw #2 — Fambo skipped known events forever).
///   3. **Reconcile** deletions: an imported occurrence whose dedup key vanished from the window is
///      deleted from Bacán — but **only when the Apple fetch is trustworthy** (see P2.2 safety below).
/// Plus **Push** Bacán → Apple: `.manual` / `.email` events with occurrences in the window are pushed
/// (recurring ones with a real `EKRecurrenceRule` — fixes flaw #3).
///
/// ### P2.2 — non-destructive reconcile (the empty-/wrong-calendar fix)
/// The reconcile phase is *never* allowed to delete a Firestore event just because Apple Calendar
/// lacks it in an untrustworthy state. Three guards gate Phase 3:
///   - **Auth guard** (`deletionsAllowed`): if calendar access isn't `.fullAccess`/granted, the delete
///     phase is skipped entirely (a revoked/limited state can never authorize destructive deletes).
///   - **Trust guard** (`fetchIsTrustworthy`): deletions run only when the Apple fetch still looks like
///     the SAME store we imported from — i.e. it contains at least one of the in-window dedup keys we
///     already hold. A fetch that shares NONE of them is untrustworthy and treated as "nothing to
///     reconcile from," NOT "delete everything." This covers an empty Apple Calendar (fresh device/sim,
///     revoked-then-empty), a *different* store (new phone), and a store that only surfaces unrelated
///     events (e.g. a simulator's Holidays/Birthdays calendars) — all of which previously nuked real
///     events. Safe upserts still run in every case.
///   - **Import-provenance guard**: only events that were themselves imported from Apple
///     (`source == .calendarImport` AND a non-empty `eventKitIdentifier`) can ever be deleted, and only
///     when that specific Apple occurrence is confirmed gone from a *trusted* fetch. App-origin events
///     (created in Bacán, no Apple id) are NEVER deleted by sync.
public enum CalendarSyncEngine {
    public struct Plan: Equatable {
        /// Brand-new imports to write to Firestore.
        public var toCreate: [FamilyEvent] = []
        /// Edited imports (same `id`, refreshed fields) to write to Firestore.
        public var toUpdate: [FamilyEvent] = []
        /// Firestore ids of imported events whose Apple occurrence disappeared.
        public var toDeleteImportIDs: [String] = []
        /// `.manual` / `.email` events to push/update into the Bacán Apple calendar.
        public var toPush: [FamilyEvent] = []

        public init() {}

        public var isEmpty: Bool {
            toCreate.isEmpty && toUpdate.isEmpty && toDeleteImportIDs.isEmpty && toPush.isEmpty
        }
    }

    /// Compute the sync plan. `now` seeds `createdAt`/`updatedAt` on new imports (injected for tests).
    /// - Parameter deletionsAllowed: caller's auth gate (P2.2). Pass `false` when EventKit access is
    ///   not `.granted`/`.fullAccess`, so a revoked/limited state can never trigger destructive deletes.
    ///   Defaults to `true`; the empty-fetch guard below is enforced regardless of this flag.
    public static func plan(
        existing: [FamilyEvent],
        imported: [ImportedEvent],
        windowStart: Date,
        windowEnd: Date,
        deletionsAllowed: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current,
        makeID: () -> String = { UUID().uuidString }
    ) -> Plan {
        var plan = Plan()

        // Existing imported events, keyed by their dedup key (stored in eventKitIdentifier).
        let existingImports = existing.filter { $0.resolvedSource == .calendarImport }
        var byKey: [String: FamilyEvent] = [:]
        for e in existingImports {
            if let key = e.eventKitIdentifier { byKey[key] = e }
        }
        let importedKeys = Set(imported.map(\.dedupKey))

        // Phases 1 & 2 — import new / update edited.
        for occ in imported {
            if let current = byKey[occ.dedupKey] {
                if importDiffers(current, from: occ) {
                    var updated = current
                    updated.title = occ.title
                    updated.startDate = occ.startDate
                    updated.endDate = occ.endDate
                    updated.isAllDay = occ.isAllDay
                    updated.location = occ.location
                    updated.notes = occ.notes
                    updated.updatedAt = now
                    plan.toUpdate.append(updated)
                }
            } else {
                plan.toCreate.append(
                    FamilyEvent(
                        id: makeID(),
                        title: occ.title,
                        startDate: occ.startDate,
                        endDate: occ.endDate,
                        isAllDay: occ.isAllDay,
                        location: occ.location,
                        notes: occ.notes,
                        recurrence: .none,           // never re-expand against Menere's occurrences()
                        assigneeIDs: [],
                        createdAt: now,
                        updatedAt: now,
                        eventKitIdentifier: occ.dedupKey,
                        source: .calendarImport
                    )
                )
            }
        }

        // Phase 3 — reconcile deletions. P2.2 SAFETY: never destroy Firestore events from an
        // untrustworthy Apple state. Reconcile only IMPORT-provenance events (source == .calendarImport,
        // non-empty eventKitIdentifier) whose occurrence sits inside the window. App-origin events are
        // never in `existingImports`, so they can never be deleted here.
        let inWindowImports = existingImports.filter { e in
            guard let key = e.eventKitIdentifier, !key.isEmpty else { return false }
            return e.startDate >= windowStart && e.startDate <= windowEnd
        }
        let inWindowImportKeys = Set(inWindowImports.compactMap(\.eventKitIdentifier))

        // Trust guard: the fetch may authorize deletions only if it still contains at least one of the
        // in-window keys we already hold — evidence it is the SAME Apple store we imported from. A fetch
        // sharing NONE of them (empty calendar, a different/new device, or a store surfacing only
        // unrelated events like a sim's holidays) is untrustworthy → skip deletes entirely. An empty
        // fetch is the degenerate case (shares nothing → untrusted), so this subsumes the empty guard.
        let fetchIsTrustworthy = !inWindowImportKeys.isDisjoint(with: importedKeys)

        if deletionsAllowed && fetchIsTrustworthy {
            for e in inWindowImports {
                guard let key = e.eventKitIdentifier else { continue }
                if !importedKeys.contains(key) {
                    plan.toDeleteImportIDs.append(e.id)
                }
            }
        }

        // Push — manual/email events with any occurrence in the window.
        for e in existing where e.resolvedSource != .calendarImport {
            let occurrences = e.occurrences(from: windowStart, to: windowEnd, calendar: calendar)
            if !occurrences.isEmpty {
                plan.toPush.append(e)
            }
        }

        return plan
    }

    /// Whether the imported occurrence's mirrored fields differ from the stored copy.
    static func importDiffers(_ event: FamilyEvent, from occ: ImportedEvent) -> Bool {
        event.title != occ.title
            || event.startDate != occ.startDate
            || event.endDate != occ.endDate
            || event.isAllDay != occ.isAllDay
            || event.location != occ.location
            || event.notes != occ.notes
    }

    // MARK: Window

    /// The sync window for a visible month: `[start-of-month − 1 month, end-of-month + 1 month]`
    /// (better than Fambo's current-month-only).
    public static func window(for visibleMonth: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let monthInterval = calendar.dateInterval(of: .month, for: visibleMonth)
            ?? DateInterval(start: visibleMonth, duration: 60 * 60 * 24 * 30)
        let start = calendar.date(byAdding: .month, value: -1, to: monthInterval.start) ?? monthInterval.start
        let end = calendar.date(byAdding: .month, value: 1, to: monthInterval.end) ?? monthInterval.end
        return (start, end)
    }
}
