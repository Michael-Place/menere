import Foundation

/// The family knowledge graph, made computable (P24). A pure, UI-free, deterministic helper that
/// surfaces the cross-entity connections the app already stores but never shows: the vet bill that
/// belongs to a pet, the deck quote that's one of five deck-project papers, the receipt that became
/// an expense. Everything here derives only from the passed-in sets — no `Date()`, no I/O — so it's
/// trivially testable and reusable from any feature.
public enum EntityGraph {
    /// Fold a vendor / issuer string to a comparison key: lowercased, trimmed, inner whitespace
    /// collapsed. `nil`/blank vendors fold to `nil` so they never cluster together.
    public static func vendorKey(_ vendor: String?) -> String? {
        guard let raw = vendor?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let collapsed = raw.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Fold a tag to a comparison key (lowercased + trimmed + whitespace-collapsed).
    public static func tagKey(_ tag: String) -> String? {
        vendorKey(tag)
    }

    // MARK: Link suggestions (Act V V1-A — receipt↔entity)

    /// A category of family entity a document can be linked to. Drives the vendor-based one-tap
    /// suggestions in the "Link to…" flow (garden→plants, vet→pets, deck/contractor→project).
    public enum LinkTarget: String, Sendable, Equatable, CaseIterable {
        case plants
        case pets
        case project
    }

    /// Vendor keyword → entity category rules. Ordered so the first match wins for the primary
    /// suggestion, but `suggestedLinkTargets` returns every category that matches (a vendor could
    /// plausibly touch two). Matched as lowercased substrings against the folded vendor key.
    private static let plantVendorKeywords = [
        "garden", "nursery", "thumb", "landscap", "greenhouse", "botanic", "florist",
        "flower", "plant", "arborist", "soil", "mulch",
    ]
    private static let petVendorKeywords = [
        "vet", "veterinar", "animal", "petco", "petsmart", "kennel", "groom",
        "paw", "canine", "kitty", "puppy", "bark",
    ]
    private static let projectVendorKeywords = [
        "deck", "daddy", "contractor", "construction", "builder", "remodel", "renovat",
        "roofing", "roofer", "septic", "fence", "concrete", "plumb", "electric", "hvac",
    ]

    /// The entity categories a receipt's vendor most likely relates to — the basis for the
    /// "Link to…" flow's one-tap SUGGESTIONS. Green Thumb Nursery → `[.plants]`, a vet bill →
    /// `[.pets]`, Deck Daddy's → `[.project]`. Pure + deterministic; returns `[]` when the vendor
    /// gives no confident signal. Order: plants, pets, project (stable for the UI).
    public static func suggestedLinkTargets(forVendor vendor: String?) -> [LinkTarget] {
        guard let key = vendorKey(vendor) else { return [] }
        var targets: [LinkTarget] = []
        if plantVendorKeywords.contains(where: key.contains) { targets.append(.plants) }
        if petVendorKeywords.contains(where: key.contains) { targets.append(.pets) }
        if projectVendorKeywords.contains(where: key.contains) { targets.append(.project) }
        return targets
    }

    /// Keywords to match a `.project`-list item's title (or its list's title) against, so the
    /// "Link to…" flow can pre-suggest the *right* project for a contractor receipt (Deck Daddy's →
    /// the "Deck" project). Combines the vendor's own significant words with the matched
    /// project-keyword vocabulary. Lowercased; short/noise words dropped.
    public static func projectMatchKeywords(forVendor vendor: String?) -> [String] {
        guard let key = vendorKey(vendor) else { return [] }
        var keywords = Set(projectVendorKeywords.filter(key.contains))
        for word in key.split(whereSeparator: { $0 == " " }) where word.count >= 4 {
            keywords.insert(String(word))
        }
        return Array(keywords)
    }

    // MARK: Related items (per-document)

    /// A cluster of documents sharing one tag — the app's lightweight notion of a "project"
    /// (a shared tag like `deck`, `glen creek`, `septic`). No new model needed.
    public struct TagGroup: Equatable, Sendable, Identifiable {
        /// The tag as it should read to a human (original casing from a representative doc).
        public var title: String
        /// Normalized key used for matching.
        public var key: String
        /// Other documents carrying this tag (never includes the anchor doc).
        public var documents: [Document]
        public var id: String { key }

        public init(title: String, key: String, documents: [Document]) {
            self.title = title
            self.key = key
            self.documents = documents
        }
    }

    /// Everything related to one anchor document. Empty groups are simply empty — the UI hides them.
    public struct RelatedItems: Equatable, Sendable {
        /// Other documents from the same vendor (normalized), newest first.
        public var sameVendor: [Document]
        /// The vendor's human-readable name (anchor doc's own casing), when it has one.
        public var vendorName: String?
        /// Shared-tag "project" clusters, ranked + de-duplicated, excluding docs already shown under
        /// `sameVendor`. Highest-overlap projects first.
        public var projects: [TagGroup]
        /// The expense this document was promoted into (matched on `Expense.documentId`), if any.
        public var linkedExpense: Expense?
        /// Linked pet CareItem ids (pass-through from the doc) — UI resolves to names.
        public var linkedPetIds: [String]
        /// Linked household member ids (pass-through from the doc) — UI resolves to names.
        public var linkedMemberIds: [String]

        public init(
            sameVendor: [Document] = [],
            vendorName: String? = nil,
            projects: [TagGroup] = [],
            linkedExpense: Expense? = nil,
            linkedPetIds: [String] = [],
            linkedMemberIds: [String] = []
        ) {
            self.sameVendor = sameVendor
            self.vendorName = vendorName
            self.projects = projects
            self.linkedExpense = linkedExpense
            self.linkedPetIds = linkedPetIds
            self.linkedMemberIds = linkedMemberIds
        }

        /// True when there's nothing to show — lets the detail hide the whole card.
        public var isEmpty: Bool {
            sameVendor.isEmpty && projects.isEmpty && linkedExpense == nil
                && linkedPetIds.isEmpty && linkedMemberIds.isEmpty
        }
    }

    /// Sort documents newest-first by their most meaningful date (printed date, else filed date).
    private static func recencySorted(_ docs: [Document]) -> [Document] {
        docs.sorted { ($0.docDate ?? $0.createdAt) > ($1.docDate ?? $1.createdAt) }
    }

    /// Compute the related items for `doc` against the family's full document / expense sets.
    /// `maxProjects` caps how many shared-tag clusters the detail card shows (keeps it scannable).
    public static func related(
        for doc: Document,
        documents: [Document],
        expenses: [Expense],
        maxProjects: Int = 3
    ) -> RelatedItems {
        let others = documents.filter { $0.id != doc.id }

        // Same vendor.
        var vendorName: String?
        var sameVendor: [Document] = []
        if let key = vendorKey(doc.vendor) {
            vendorName = doc.vendor?.trimmingCharacters(in: .whitespacesAndNewlines)
            sameVendor = recencySorted(others.filter { vendorKey($0.vendor) == key })
        }
        let vendorIds = Set(sameVendor.map(\.id))

        // Shared-tag projects. Build a group per shared tag, then rank by overlap and drop any group
        // whose docs are already fully covered by the vendor list or by a larger kept group.
        var groups: [TagGroup] = []
        var seenKeys = Set<String>()
        for tag in doc.tags {
            guard let key = tagKey(tag), !seenKeys.contains(key) else { continue }
            seenKeys.insert(key)
            // Docs that share this tag (by normalized key), excluding ones already under same-vendor.
            let shared = recencySorted(
                others.filter { other in
                    !vendorIds.contains(other.id)
                        && other.tags.contains { tagKey($0) == key }
                }
            )
            guard !shared.isEmpty else { continue }
            groups.append(TagGroup(title: tag, key: key, documents: shared))
        }
        // Rank by size (desc), then title for determinism.
        groups.sort { ($0.documents.count, $1.title) > ($1.documents.count, $0.title) }
        // Greedy de-dup: keep a group only if it adds documents not already covered by kept groups.
        var kept: [TagGroup] = []
        var covered = Set<String>()
        for group in groups {
            let ids = Set(group.documents.map(\.id))
            if ids.isSubset(of: covered) { continue }
            kept.append(group)
            covered.formUnion(ids)
            if kept.count >= maxProjects { break }
        }

        // Linked expense (promoted from this doc).
        let linkedExpense = expenses.first { $0.documentId == doc.id }

        return RelatedItems(
            sameVendor: sameVendor,
            vendorName: vendorName,
            projects: kept,
            linkedExpense: linkedExpense,
            linkedPetIds: doc.linkedPetIds,
            linkedMemberIds: doc.linkedMemberIds
        )
    }

    // MARK: Collections (Family-Brain-wide clustering)

    /// A cluster of documents in the Brain — grouped by a shared vendor or a shared tag/project.
    public struct Collection: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable, Equatable {
            case vendor
            case project
        }
        public var kind: Kind
        /// Normalized match key (unique within a kind).
        public var key: String
        /// Human-readable name (original casing from a representative doc).
        public var title: String
        /// Member document ids, newest first.
        public var documentIds: [String]
        /// Sum of the cluster's document amounts (0 when none carry an amount).
        public var total: Double
        public var id: String { "\(kind.rawValue):\(key)" }
        public var count: Int { documentIds.count }

        public init(kind: Kind, key: String, title: String, documentIds: [String], total: Double) {
            self.kind = kind
            self.key = key
            self.title = title
            self.documentIds = documentIds
            self.total = total
        }
    }

    /// Cluster the whole Brain into collections for the "Collections" lens. Vendors first (crisp,
    /// meaningful — a vet, a contractor, a bank), then tag/"project" clusters. Only clusters with
    /// `>= minCount` docs are returned; singletons stay in the flat list.
    ///
    /// A greedy *overlap* de-dup keeps the lens tight: a candidate is dropped when an already-kept
    /// (larger / vendor) cluster already covers `>= overlapThreshold` of its documents. This collapses
    /// near-duplicate tag sprawl (e.g. `vet` ≈ `vaccination` ≈ `sprinkle`) and tag clusters subsumed by
    /// a vendor, leaving a scannable set of *dominant* groupings rather than every raw tag. Vendors are
    /// considered first, so they always survive.
    public static func collections(
        documents: [Document],
        minCount: Int = 2,
        overlapThreshold: Double = 0.6
    ) -> [Collection] {
        // --- Vendor clusters ---
        var vendorDocs: [String: [Document]] = [:]
        var vendorTitle: [String: String] = [:]
        for doc in documents {
            guard let key = vendorKey(doc.vendor) else { continue }
            vendorDocs[key, default: []].append(doc)
            if vendorTitle[key] == nil {
                vendorTitle[key] = doc.vendor?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        var vendorCollections: [Collection] = vendorDocs.compactMap { key, docs in
            guard docs.count >= minCount else { return nil }
            let sorted = recencySorted(docs)
            return Collection(
                kind: .vendor,
                key: key,
                title: vendorTitle[key] ?? key,
                documentIds: sorted.map(\.id),
                total: docs.compactMap(\.amount).reduce(0, +)
            )
        }
        vendorCollections.sort { ($0.count, $1.title) > ($1.count, $0.title) }

        // --- Tag / project clusters ---
        var tagDocs: [String: [Document]] = [:]
        var tagTitle: [String: String] = [:]
        for doc in documents {
            var seen = Set<String>()
            for tag in doc.tags {
                guard let key = tagKey(tag), !seen.contains(key) else { continue }
                seen.insert(key)
                tagDocs[key, default: []].append(doc)
                if tagTitle[key] == nil { tagTitle[key] = tag }
            }
        }
        var tagCollections: [Collection] = tagDocs.compactMap { key, docs in
            guard docs.count >= minCount else { return nil }
            let sorted = recencySorted(docs)
            return Collection(
                kind: .project,
                key: key,
                title: (tagTitle[key] ?? key).capitalized,
                documentIds: sorted.map(\.id),
                total: docs.compactMap(\.amount).reduce(0, +)
            )
        }
        tagCollections.sort { ($0.count, $1.title) > ($1.count, $0.title) }

        // Greedy overlap de-dup across vendors (first) then tags: drop a candidate when an already-kept
        // cluster covers `>= overlapThreshold` of its documents. Vendors always survive; tags survive
        // only when they bring enough documents a bigger cluster didn't already cover.
        var kept: [Collection] = []
        for candidate in vendorCollections + tagCollections {
            let ids = Set(candidate.documentIds)
            guard !ids.isEmpty else { continue }
            let subsumed = kept.contains { existing in
                let existingIds = Set(existing.documentIds)
                let shared = ids.intersection(existingIds).count
                return Double(shared) / Double(ids.count) >= overlapThreshold
            }
            if !subsumed { kept.append(candidate) }
        }
        return kept
    }
}
