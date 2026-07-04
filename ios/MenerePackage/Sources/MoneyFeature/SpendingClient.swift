import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// The AI "This month, in a nutshell" recap shown atop the spending-insights screen.
public struct SpendingSummary: Equatable, Sendable {
    /// 2-3 warm, family-voice sentences on where the money went.
    public var summary: String
    /// One useful, non-judgmental observation or gentle nudge.
    public var insight: String

    public init(summary: String, insight: String) {
        self.summary = summary
        self.insight = insight
    }
}

/// A compact, JSON-encodable line item sent to `summarizeSpending`. The client aggregates + dedups +
/// categorizes locally (`SpendingInsights`), then forwards just the featured month's categorized
/// items so the function stays a dumb model proxy.
public struct SpendingLinePayload: Equatable, Sendable {
    public var category: String
    public var vendor: String?
    public var amount: Double
    public var date: String

    public init(category: String, vendor: String?, amount: Double, date: String) {
        self.category = category
        self.vendor = vendor
        self.amount = amount
        self.date = date
    }

    /// Build from an aggregated line. `date` is an ISO `yyyy-MM-dd` string (stable, tz-free).
    public init(line: SpendingInsights.Line) {
        self.category = line.category.displayName
        self.vendor = line.vendor
        self.amount = line.amount
        self.date = Self.isoDay.string(from: line.date)
    }

    var dictionary: [String: Any] {
        var d: [String: Any] = ["category": category, "amount": amount, "date": date]
        if let vendor, !vendor.isEmpty { d["vendor"] = vendor }
        return d
    }

    static let isoDay: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}

/// Wraps the `summarizeSpending` HTTPS callable. Auth-derived server-side; the client forwards the
/// featured month's label + categorized line items.
@DependencyClient
public struct SpendingClient: Sendable {
    public var summarize: @Sendable (_ month: String, _ lines: [SpendingLinePayload]) async throws -> SpendingSummary
}

public enum SpendingClientError: Error, Equatable {
    case invalidResponse
}

extension SpendingClient: DependencyKey {
    public static let liveValue = SpendingClient(
        summarize: { month, lines in
            let callable = Functions.functions(region: "us-central1").httpsCallable("summarizeSpending")
            let payload: [String: Any] = [
                "month": month,
                "currency": "USD",
                "lines": lines.map(\.dictionary),
            ]
            let result = try await callable.call(payload)
            guard
                let data = result.data as? [String: Any],
                let summary = data["summary"] as? String,
                !summary.isEmpty
            else { throw SpendingClientError.invalidResponse }
            let insight = (data["insight"] as? String) ?? ""
            return SpendingSummary(summary: summary, insight: insight)
        }
    )
}

extension DependencyValues {
    public var spending: SpendingClient {
        get { self[SpendingClient.self] }
        set { self[SpendingClient.self] = newValue }
    }
}
