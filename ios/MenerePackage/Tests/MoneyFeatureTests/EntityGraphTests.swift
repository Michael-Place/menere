import FamilyDomain
import Foundation
import XCTest

/// The pure P24 relatedness/clustering helper. Lives in the Money test target because it already
/// links FamilyDomain (which owns `EntityGraph`, `Document`, and `Expense`).
final class EntityGraphTests: XCTestCase {
    private func doc(
        _ id: String,
        title: String = "Doc",
        vendor: String? = nil,
        tags: [String] = [],
        amount: Double? = nil,
        petIds: [String] = [],
        memberIds: [String] = []
    ) -> Document {
        Document(
            id: id,
            title: title,
            tags: tags,
            linkedMemberIds: memberIds,
            linkedPetIds: petIds,
            amount: amount,
            vendor: vendor,
            uploadedBy: "u"
        )
    }

    // MARK: related(for:)

    func testSameVendorNormalizesAndExcludesSelf() {
        let anchor = doc("a", vendor: "Green Thumb Nursery")
        let docs = [
            anchor,
            doc("b", vendor: "green thumb   nursery"),   // casing + whitespace variant
            doc("c", vendor: "Deck Daddy's LLC"),
        ]
        let related = EntityGraph.related(for: anchor, documents: docs, expenses: [])
        XCTAssertEqual(related.sameVendor.map(\.id), ["b"])
        XCTAssertEqual(related.vendorName, "Green Thumb Nursery")
    }

    func testSharedTagProjectsRankAndExcludeVendorDocs() {
        let anchor = doc("a", vendor: "Deck Daddy's", tags: ["deck", "quote"])
        let docs = [
            anchor,
            doc("b", vendor: "Deck Daddy's", tags: ["deck"]),   // same vendor → not a project row
            doc("c", tags: ["deck", "construction"]),
            doc("d", tags: ["deck"]),
            doc("e", tags: ["unrelated"]),
        ]
        let related = EntityGraph.related(for: anchor, documents: docs, expenses: [])
        // b is under sameVendor and must not reappear in the deck project group.
        XCTAssertEqual(related.sameVendor.map(\.id), ["b"])
        let deck = related.projects.first { $0.key == "deck" }
        XCTAssertNotNil(deck)
        XCTAssertEqual(Set(deck!.documents.map(\.id)), ["c", "d"])
    }

    func testLinkedExpenseMatchesDocumentId() {
        let anchor = doc("a", amount: 84)
        let expense = Expense(amount: 84, source: .receiptScan, documentId: "a")
        let related = EntityGraph.related(for: anchor, documents: [anchor], expenses: [expense])
        XCTAssertEqual(related.linkedExpense?.id, expense.id)
    }

    func testEmptyWhenNoConnections() {
        let anchor = doc("a", vendor: "Solo Vendor", tags: ["unique"])
        let related = EntityGraph.related(for: anchor, documents: [anchor], expenses: [])
        XCTAssertTrue(related.isEmpty)
        XCTAssertTrue(related.projects.isEmpty)
        XCTAssertTrue(related.sameVendor.isEmpty)
    }

    // MARK: collections

    func testCollectionsClusterVendorsAndTagsAboveMinCount() {
        let docs = [
            doc("1", vendor: "Vet Co", tags: ["vaccination"], amount: 50),
            doc("2", vendor: "Vet Co", tags: ["vaccination"]),
            doc("3", vendor: "Vet Co", tags: ["vaccination"]),
            doc("4", tags: ["deck"]),                 // singleton tag → dropped
            doc("5", vendor: "One Off", tags: ["misc"]),  // singleton vendor → dropped
        ]
        let collections = EntityGraph.collections(documents: docs)
        // The Vet Co vendor cluster survives (3 docs, $50 total).
        let vet = collections.first { $0.kind == .vendor && $0.key == "vet co" }
        XCTAssertNotNil(vet)
        XCTAssertEqual(vet?.count, 3)
        XCTAssertEqual(vet?.total, 50)
        // The "vaccination" tag cluster is fully covered by the vendor cluster → de-duped away.
        XCTAssertFalse(collections.contains { $0.kind == .project && $0.key == "vaccination" })
        // Singletons never appear.
        XCTAssertFalse(collections.contains { $0.key == "deck" })
        XCTAssertFalse(collections.contains { $0.key == "one off" })
    }

    func testCollectionsKeepDistinctProjectCluster() {
        let docs = [
            doc("1", vendor: "Vet Co", tags: ["vaccination"]),
            doc("2", vendor: "Vet Co", tags: ["vaccination"]),
            doc("3", tags: ["deck"]),
            doc("4", tags: ["deck"]),
        ]
        let collections = EntityGraph.collections(documents: docs)
        // The deck project (2 docs, no vendor) is distinct from the vet vendor cluster → kept.
        XCTAssertTrue(collections.contains { $0.kind == .project && $0.key == "deck" })
    }
}
