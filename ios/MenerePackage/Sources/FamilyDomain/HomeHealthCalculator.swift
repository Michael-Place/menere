import Foundation

/// Which way the home-health number is moving vs. the last calculation.
public enum HomeHealthTrend: String, Codable, Sendable, Equatable {
    case improving
    case stable
    case declining

    public var displayName: String {
        switch self {
        case .improving: "Improving"
        case .stable: "Steady"
        case .declining: "Slipping"
        }
    }
}

/// The computed home-maintenance readiness (P29, ported from Fambo's `HomeHealthScore`). `overall`
/// is 0–100 across the applicable categories; `categoryScores` is keyed by
/// ``MaintenanceCategory`` raw value. Purely derived — never persisted; recomputed from the house
/// ``CareItem``s + the ``HomeProfile`` on demand.
public struct HomeHealthScore: Equatable, Sendable {
    public var overall: Int
    public var categoryScores: [String: Int]
    public var trend: HomeHealthTrend
    /// Materialized maintenance tasks currently within their frequency window.
    public var completedMaintenanceCount: Int
    /// Applicable templates from the knowledge base (the scoring denominator).
    public var totalMaintenanceCount: Int
    public var calculatedAt: Date

    public init(
        overall: Int = 100,
        categoryScores: [String: Int] = [:],
        trend: HomeHealthTrend = .stable,
        completedMaintenanceCount: Int = 0,
        totalMaintenanceCount: Int = 0,
        calculatedAt: Date = .now
    ) {
        self.overall = overall
        self.categoryScores = categoryScores
        self.trend = trend
        self.completedMaintenanceCount = completedMaintenanceCount
        self.totalMaintenanceCount = totalMaintenanceCount
        self.calculatedAt = calculatedAt
    }

    /// The categories that have at least one applicable template, with their score, ordered by the
    /// canonical ``MaintenanceCategory`` declaration order — for the per-category breakdown UI.
    public var categoryBreakdown: [(category: MaintenanceCategory, score: Int)] {
        MaintenanceCategory.allCases.compactMap { cat in
            categoryScores[cat.rawValue].map { (cat, $0) }
        }
    }
}

/// Scores the household's home-maintenance readiness (P29-C2, ported from Fambo's
/// `HomeHealthCalculator`). Frequency-window scoring: a knowledge-base template counts as "on track"
/// when a materialized house ``CareTask`` (carrying its `maintenanceTemplateID`) has a `lastDoneAt`
/// inside its frequency window. Per applicable category → percent on-track; overall = the equal-weight
/// average across categories that have applicable tasks.
public enum HomeHealthCalculator {

    /// - Parameters:
    ///   - careItems: The household's care items (house maintenance ones are filtered internally).
    ///   - profile: The home profile used to filter the applicable library.
    ///   - previousScore: Prior score, to derive the trend.
    public static func calculate(
        careItems: [CareItem],
        profile: HomeProfile,
        previousScore: HomeHealthScore? = nil,
        now: Date = Date()
    ) -> HomeHealthScore {
        let applicable = MaintenanceKnowledgeBase.filterForHome(profile)

        // Group applicable templates by category.
        var byCategory: [MaintenanceCategory: [MaintenanceTemplate]] = [:]
        for t in applicable { byCategory[t.category, default: []].append(t) }

        // Which materialized templates are currently within their frequency window (done recently).
        let cal = Calendar.current
        var onTrackTemplateIDs: Set<String> = []
        for item in careItems {
            for task in item.tasks {
                guard let templateID = task.maintenanceTemplateID,
                      let completedAt = task.lastDoneAt,
                      let template = applicable.first(where: { $0.id == templateID })
                else { continue }
                let windowStart = cal.date(byAdding: .day, value: -template.intervalDays, to: now) ?? now
                if completedAt >= windowStart { onTrackTemplateIDs.insert(templateID) }
            }
        }

        var categoryScores: [String: Int] = [:]
        var totalOnTrack = 0
        var totalApplicable = 0
        for category in MaintenanceCategory.allCases {
            let tasks = byCategory[category] ?? []
            guard !tasks.isEmpty else { continue }
            let onTrack = tasks.filter { onTrackTemplateIDs.contains($0.id) }.count
            categoryScores[category.rawValue] = Int((Double(onTrack) / Double(tasks.count)) * 100.0)
            totalOnTrack += onTrack
            totalApplicable += tasks.count
        }

        let overall: Int
        if categoryScores.isEmpty {
            overall = 100   // no applicable tasks at all ⇒ nothing to keep up with
        } else {
            overall = categoryScores.values.reduce(0, +) / categoryScores.count
        }

        let trend: HomeHealthTrend
        if let previous = previousScore {
            let delta = overall - previous.overall
            trend = delta > 5 ? .improving : (delta < -5 ? .declining : .stable)
        } else {
            trend = .stable
        }

        return HomeHealthScore(
            overall: overall,
            categoryScores: categoryScores,
            trend: trend,
            completedMaintenanceCount: totalOnTrack,
            totalMaintenanceCount: totalApplicable,
            calculatedAt: now
        )
    }
}
