import Dependencies
import DependenciesMacros
import Foundation
import WineDomain

/// Enriches a catalog `Wine` from free, on-device-reachable open-data sources, recording per-field
/// `Provenance` so the UI can show "verified" vs "from the label". Phase 2 wires two authoritative
/// sources — Open Food Facts (barcode) and Wikidata (grape → wine color). TTB (Phase 3) and AI
/// gap-fill (Phase 4) slot in later behind the same merge engine.
///
/// `enrich` is resilient: each source runs concurrently under a timeout, and a single source failing
/// or timing out never fails the whole enrichment — at worst it returns the input wine unchanged.
@DependencyClient
public struct EnrichmentClient: Sendable {
    public var enrich: @Sendable (_ wine: Wine, _ candidate: WineCandidate) async throws -> Wine
}

extension EnrichmentClient: DependencyKey {
    /// Per-source timeout. A slow source must never block resolve.
    static let sourceTimeout: Duration = .seconds(10)

    public static let liveValue: EnrichmentClient = EnrichmentClient(
        enrich: { wine, candidate in
            // Pass 1 — authoritative open-data sources. Run concurrently; each is individually resilient
            // (nil on any error). These own identity + hard facts and outrank the AI gap-fill below.
            async let offContribution = resilient {
                guard let barcode = candidate.barcode, !barcode.isEmpty else { return nil }
                return try await OpenFoodFactsSource.fetch(barcode: barcode)
            }
            async let wikidataContribution = resilient {
                let grapes = candidate.grapes.isEmpty ? wine.grapes : candidate.grapes
                return try await WikidataSource.fetch(grapes: grapes)
            }
            async let ttbContribution = resilient {
                let candidateProducer = candidate.producer?.trimmingCharacters(in: .whitespacesAndNewlines)
                let producer = (candidateProducer?.isEmpty == false) ? candidateProducer! : wine.producer
                return try await TTBColaSource.fetch(producer: producer, name: candidate.name ?? wine.name)
            }

            // Order is informational only — equal-tier ties are broken by confidence in the merge.
            let authoritativeContributions = await [offContribution, wikidataContribution, ttbContribution]
                .compactMap { $0 }
            let wineAfterAuthoritative = mergeEnrichment(base: wine, contributions: authoritativeContributions)

            // Pass 2 — on-device AI gap-fill (lowest authority). Only runs when descriptive fields are
            // still empty after the authoritative pass, and only generates those gaps. Fully resilient:
            // any unavailability/timeout/error leaves `wineAfterAuthoritative` untouched.
            guard !FoundationModelSource.emptyDescriptiveFields(of: wineAfterAuthoritative).isEmpty else {
                return wineAfterAuthoritative
            }
            let llmContribution = await resilient {
                await FoundationModelSource.fetch(wine: wineAfterAuthoritative)
            }
            guard let llmContribution else { return wineAfterAuthoritative }
            return mergeEnrichment(base: wineAfterAuthoritative, contributions: [llmContribution])
        }
    )

    /// Wrap a source call so any throw/timeout collapses to `nil` (never fails the whole enrichment).
    static func resilient(
        _ operation: @escaping @Sendable () async throws -> SourceContribution?
    ) async -> SourceContribution? {
        do {
            return try await withTimeout(sourceTimeout, operation: operation)
        } catch {
            return nil
        }
    }
}

/// Race `operation` against a sleep; whichever finishes first wins, the other is cancelled.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw EnrichmentTimeoutError()
        }
        defer { group.cancelAll() }
        let result = try await group.next()!
        return result
    }
}

struct EnrichmentTimeoutError: Error {}

public extension DependencyValues {
    var enrichment: EnrichmentClient {
        get { self[EnrichmentClient.self] }
        set { self[EnrichmentClient.self] = newValue }
    }
}
