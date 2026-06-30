import ComposableArchitecture
import WineDomain
import XCTest

@testable import JournalFeature

/// `TestStore` coverage for the read-only tasting detail. Minimal — it guards the wiring and that
/// `.task` is inert (no state change), since the view holds the real logic.
@MainActor
final class TastingDetailReducerTests: XCTestCase {
    func testStateExposesTastingAndWine() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let url = URL(string: "https://example.com/p.jpg")!
        let tasting = Tasting(
            id: "t1",
            wineId: wine.id,
            date: Date(timeIntervalSince1970: 1000),
            ratingStars: 4.5,
            rating100: 95,
            note: "Lovely",
            sat: SATNote(appearance: "Deep ruby", nose: "Cassis", palate: "Long", conclusions: "Hold"),
            photoURLs: [url]
        )

        let store = TestStore(
            initialState: TastingDetailReducer.State(tasting: tasting, wine: wine)
        ) {
            TastingDetailReducer()
        }

        XCTAssertEqual(store.state.tasting, tasting)
        XCTAssertEqual(store.state.wine, wine)
        XCTAssertEqual(store.state.tasting.sat?.nose, "Cassis")
        XCTAssertEqual(store.state.tasting.photoURLs, [url])

        // .task is a no-op for the read-only UX1 detail.
        await store.send(.task)
    }
}
