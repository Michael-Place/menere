import Dependencies
import DependenciesMacros
import EnrichmentClient
import PersistenceClient
import WineDomain

/// Resolves a scanned `WineCandidate` to a catalog `Wine`, hitting the shared `wines` cache first and
/// creating an identity-only record on a miss. This is the M3 catalog seam: scanning produces a
/// candidate, resolving turns it into a canonical, deduped bottling.
///
/// Modeled as a `@DependencyClient` so TCA features inject it and tests can swap it.
@DependencyClient
public struct CatalogClient: Sendable {
    /// Resolve a confirmed candidate to a catalog `Wine`. Throws `CatalogError.insufficientIdentity`
    /// when the candidate lacks the producer needed to form a canonical key (e.g. barcode-only scans).
    public var resolve: @Sendable (_ candidate: WineCandidate) async throws -> Wine
}

/// Failures the catalog can surface to callers.
public enum CatalogError: Error {
    /// The candidate can't be turned into a canonical `Wine` (no producer ⇒ no canonical key).
    case insufficientIdentity
}

extension CatalogClient: DependencyKey {
    public static let liveValue: CatalogClient = CatalogClient(
        resolve: { candidate in
            @Dependency(\.persistence) var persistence
            @Dependency(\.enrichment) var enrichment

            // Identity: derive the canonical bottling (and its Firestore key) from the candidate.
            guard let provisional = candidate.provisionalWine else {
                throw CatalogError.insufficientIdentity
            }

            // Cache hit: the shared catalog already knows this bottling.
            if let cached = try await persistence.wine(provisional.id) {
                return cached
            }

            // Cache miss: enrich from free open-data sources (resilient — never fails resolve), then
            // persist the enriched bottling and return it.
            let enriched = try await enrichment.enrich(provisional, candidate)
            try await persistence.upsertWine(enriched)
            return enriched
        }
    )
}

public extension DependencyValues {
    var catalog: CatalogClient {
        get { self[CatalogClient.self] }
        set { self[CatalogClient.self] = newValue }
    }
}
