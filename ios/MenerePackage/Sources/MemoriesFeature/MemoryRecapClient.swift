import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// One month's memory, stripped to plain text on the phone and forwarded to `memoryMonthSummary`
/// (P28-C3). The function only ever sees plain text + first names — the collage/markdown stays local.
public struct MemoryRecapPayload: Equatable, Sendable {
    public var title: String
    public var text: String
    public var milestone: String
    public var kidNames: [String]
    public var date: String

    public init(title: String, text: String, milestone: String, kidNames: [String], date: String) {
        self.title = title
        self.text = text
        self.milestone = milestone
        self.kidNames = kidNames
        self.date = date
    }

    var dictionary: [String: Any] {
        [
            "title": title,
            "text": text,
            "milestone": milestone,
            "kidNames": kidNames,
            "date": date,
        ]
    }

    static let isoDay: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}

/// Wraps the `memoryMonthSummary` HTTPS callable — the AI "Recap this month ✨" affordance on each
/// month header in the Memories timeline. Auth is derived server-side; the client forwards the
/// month's label + its plain-text memories and gets back a warm 2-4 sentence recap.
@DependencyClient
public struct MemoryRecapClient: Sendable {
    public var recap: @Sendable (_ month: String, _ memories: [MemoryRecapPayload]) async throws -> String
}

public enum MemoryRecapClientError: Error, Equatable {
    case invalidResponse
}

extension MemoryRecapClient: DependencyKey {
    public static let liveValue = MemoryRecapClient(
        recap: { month, memories in
            let callable = Functions.functions(region: "us-central1").httpsCallable("memoryMonthSummary")
            let payload: [String: Any] = [
                "month": month,
                "memories": memories.map(\.dictionary),
            ]
            let result = try await callable.call(payload)
            guard
                let data = result.data as? [String: Any],
                let recap = data["recap"] as? String,
                !recap.isEmpty
            else { throw MemoryRecapClientError.invalidResponse }
            return recap
        }
    )
}

extension DependencyValues {
    public var memoryRecap: MemoryRecapClient {
        get { self[MemoryRecapClient.self] }
        set { self[MemoryRecapClient.self] = newValue }
    }
}
