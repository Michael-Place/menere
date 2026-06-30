import ComposableArchitecture
import PersistenceClient
import StorageClient
import WineDomain
import XCTest

@testable import JournalFeature

/// `TestStore` coverage for the M5 Phase 2 "Log a tasting" form. Stubs `\.persistence` and
/// `\.storage` so the tests stay offline, and pins `\.uuid` to `.incrementing` so the generated
/// `Tasting.id` (and therefore the photo upload path) is deterministic.
@MainActor
final class TastingFormReducerTests: XCTestCase {
    private struct StubError: Error, LocalizedError {
        var errorDescription: String? { "upload failed" }
    }

    /// The first `.incrementing` uuid stringifies to this — used as the tasting id.
    private let firstId = "00000000-0000-0000-0000-000000000000"
    private let epoch = Date(timeIntervalSince1970: 0)

    /// 1. Happy path with photos: bytes appended via `.photosPicked`, fields set via bindings, both
    /// photos uploaded sequentially, the exact `Tasting` persisted, then `.delegate(.saved)`.
    func testSaveHappyPathWithPhotos() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let url = URL(string: "https://example.com/\(firstId)/p.jpg")!

        let captured = LockIsolated<(hid: String, tasting: Tasting)?>(nil)
        let capturedPhotoUid = LockIsolated<String?>(nil)

        let store = TestStore(initialState: TastingFormReducer.State(wine: wine, hid: "test-hid", uid: "test-uid")) {
            TastingFormReducer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.storage.uploadTastingPhoto = { uid, _, _ in
                capturedPhotoUid.setValue(uid)
                return url
            }
            $0.persistence.saveTasting = { hid, tasting in
                captured.setValue((hid, tasting))
            }
        }

        await store.send(.photosPicked([Data("a".utf8), Data("b".utf8)])) {
            $0.pendingPhotos = [Data("a".utf8), Data("b".utf8)]
        }
        await store.send(.binding(.set(\.ratingStars, 4.5))) {
            $0.ratingStars = 4.5
        }
        await store.send(.binding(.set(\.note, "Lovely"))) {
            $0.note = "Lovely"
        }
        await store.send(.binding(.set(\.nose, "Cassis"))) {
            $0.nose = "Cassis"
        }

        let expected = Tasting(
            id: firstId,
            wineId: wine.id,
            bottleId: nil,
            date: epoch,
            ratingStars: 4.5,
            rating100: nil,
            note: "Lovely",
            sat: SATNote(appearance: nil, nose: "Cassis", palate: nil, conclusions: nil),
            photoURLs: [url, url],
            withWhom: nil,
            occasion: nil,
            createdAt: epoch
        )

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.success(expected))) {
            $0.isSaving = false
        }
        await store.receive(.delegate(.saved(expected)))

        XCTAssertEqual(captured.value?.hid, "test-hid")
        XCTAssertEqual(capturedPhotoUid.value, "test-uid")
        XCTAssertEqual(captured.value?.tasting.wineId, wine.id)
        XCTAssertEqual(captured.value?.tasting.id, firstId)
        XCTAssertEqual(captured.value?.tasting.photoURLs.count, 2)
        XCTAssertEqual(captured.value?.tasting.ratingStars, 4.5)
        XCTAssertEqual(captured.value?.tasting.note, "Lovely")
        XCTAssertEqual(captured.value?.tasting.sat?.nose, "Cassis")
        XCTAssertNil(captured.value?.tasting.sat?.appearance)
    }

    /// 2. No photos: storage must NOT be called; `photoURLs` is empty; still saves + delegates.
    func testSaveNoPhotosDoesNotCallStorage() async {
        let wine = Wine(producer: "Ridge Vineyards", name: "Monte Bello", vintage: 2018)

        let store = TestStore(initialState: TastingFormReducer.State(wine: wine, hid: "test-hid", uid: "test-uid")) {
            TastingFormReducer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.storage.uploadTastingPhoto = { _, _, _ in
                XCTFail("Storage must not be called when there are no pending photos")
                return URL(string: "https://example.com/should-not-happen.jpg")!
            }
            $0.persistence.saveTasting = { _, _ in }
        }

        let expected = Tasting(
            id: firstId,
            wineId: wine.id,
            date: epoch,
            photoURLs: [],
            createdAt: epoch
        )

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.success(expected))) {
            $0.isSaving = false
        }
        await store.receive(.delegate(.saved(expected)))
    }

    /// 3. Upload failure: storage throws → `.failure`, `errorMessage` set, persistence NEVER called,
    /// and no `.delegate(.saved)` (exhaustive TestStore enforces the latter two).
    func testUploadFailureSurfacesErrorAndDoesNotPersist() async {
        let wine = Wine(producer: "Anything", vintage: 2020)

        let store = TestStore(initialState: TastingFormReducer.State(wine: wine, hid: "test-hid", uid: "test-uid")) {
            TastingFormReducer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.storage.uploadTastingPhoto = { _, _, _ in throw StubError() }
            $0.persistence.saveTasting = { _, _ in
                XCTFail("Persistence must not be called when a photo upload fails")
            }
        }

        await store.send(.photosPicked([Data("a".utf8)])) {
            $0.pendingPhotos = [Data("a".utf8)]
        }
        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.failure("upload failed"))) {
            $0.isSaving = false
            $0.errorMessage = "upload failed"
        }
    }

    /// 4. SAT all-empty → the persisted `Tasting.sat` is nil.
    func testSaveWithEmptySATProducesNilNote() async {
        let wine = Wine(producer: "Domaine Leflaive", vintage: 2019)

        let captured = LockIsolated<Tasting?>(nil)

        let store = TestStore(initialState: TastingFormReducer.State(wine: wine, hid: "test-hid", uid: "test-uid")) {
            TastingFormReducer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.persistence.saveTasting = { _, tasting in captured.setValue(tasting) }
        }

        let expected = Tasting(
            id: firstId,
            wineId: wine.id,
            date: epoch,
            sat: nil,
            photoURLs: [],
            createdAt: epoch
        )

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.success(expected))) {
            $0.isSaving = false
        }
        await store.receive(.delegate(.saved(expected)))

        XCTAssertNil(captured.value?.sat)
    }

    /// 5. `.task` loads cellared bottles filtered down to THIS wine.
    func testTaskLoadsBottlesFilteredByWine() async {
        let wine = Wine(producer: "Penfolds", name: "Grange", vintage: 2016)
        let mine = Bottle(id: "b1", wineId: wine.id, quantity: 2)
        let other = Bottle(id: "b2", wineId: "some-other-wine", quantity: 1)

        let store = TestStore(initialState: TastingFormReducer.State(wine: wine, hid: "test-hid", uid: "test-uid")) {
            TastingFormReducer()
        } withDependencies: {
            $0.persistence.bottles = { _ in [mine, other] }
        }

        await store.send(.task)
        await store.receive(.bottlesLoaded([mine])) {
            $0.availableBottles = [mine]
        }
    }

    /// 7. UX2a edit mode with a new photo: existing remote URLs are preserved and the newly-picked
    /// photo is appended; id/date/createdAt survive; storage is called exactly once (for the new one).
    func testEditSaveKeepsIDAndPreservesPhotos() async {
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015)
        let u1 = URL(string: "https://example.com/u1.jpg")!
        let u2 = URL(string: "https://example.com/u2.jpg")!
        let u3 = URL(string: "https://example.com/u3.jpg")!
        let existingTasting = Tasting(
            id: "existing-tasting-id",
            wineId: wine.id,
            bottleId: "b1",
            date: Date(timeIntervalSince1970: 1000),
            ratingStars: 4.0,
            rating100: 92,
            note: "Old note",
            sat: SATNote(appearance: "Ruby", nose: "Cassis", palate: "Long", conclusions: "Hold"),
            photoURLs: [u1, u2],
            withWhom: "Dad",
            occasion: "Dinner",
            createdAt: Date(timeIntervalSince1970: 500)
        )

        let captured = LockIsolated<(hid: String, tasting: Tasting)?>(nil)
        let uploadCount = LockIsolated(0)

        let store = TestStore(
            initialState: TastingFormReducer.State(editing: existingTasting, wine: wine, hid: "test-hid", uid: "test-uid")
        ) {
            TastingFormReducer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.storage.uploadTastingPhoto = { _, _, _ in
                uploadCount.withValue { $0 += 1 }
                return u3
            }
            $0.persistence.saveTasting = { hid, tasting in captured.setValue((hid, tasting)) }
        }

        XCTAssertEqual(store.state.editingID, "existing-tasting-id")
        XCTAssertEqual(store.state.existingPhotoURLs, [u1, u2])
        XCTAssertEqual(store.state.note, "Old note")
        XCTAssertEqual(store.state.rating100Text, "92")

        await store.send(.photosPicked([Data("new".utf8)])) {
            $0.pendingPhotos = [Data("new".utf8)]
        }

        let expected = Tasting(
            id: "existing-tasting-id",
            wineId: wine.id,
            bottleId: "b1",
            date: Date(timeIntervalSince1970: 1000),
            ratingStars: 4.0,
            rating100: 92,
            note: "Old note",
            sat: SATNote(appearance: "Ruby", nose: "Cassis", palate: "Long", conclusions: "Hold"),
            photoURLs: [u1, u2, u3],
            withWhom: "Dad",
            occasion: "Dinner",
            createdAt: Date(timeIntervalSince1970: 500)
        )

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.success(expected))) {
            $0.isSaving = false
        }
        await store.receive(.delegate(.saved(expected)))

        XCTAssertEqual(uploadCount.value, 1)
        XCTAssertEqual(captured.value?.tasting.id, "existing-tasting-id")
        XCTAssertEqual(captured.value?.tasting.date, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(captured.value?.tasting.createdAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(captured.value?.tasting.photoURLs, [u1, u2, u3])
    }

    /// 8. UX2a edit mode with no new photos: storage is NEVER called; existing URLs are kept as-is.
    func testEditSaveNoNewPhotosDoesNotCallStorage() async {
        let wine = Wine(producer: "Ridge Vineyards", name: "Monte Bello", vintage: 2018)
        let u1 = URL(string: "https://example.com/u1.jpg")!
        let existingTasting = Tasting(
            id: "t-existing",
            wineId: wine.id,
            date: Date(timeIntervalSince1970: 2000),
            photoURLs: [u1],
            createdAt: Date(timeIntervalSince1970: 1500)
        )

        let store = TestStore(
            initialState: TastingFormReducer.State(editing: existingTasting, wine: wine, hid: "test-hid", uid: "test-uid")
        ) {
            TastingFormReducer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.date = .constant(epoch)
            $0.storage.uploadTastingPhoto = { _, _, _ in
                XCTFail("Storage must not be called when there are no new photos")
                return URL(string: "https://example.com/should-not-happen.jpg")!
            }
            $0.persistence.saveTasting = { _, _ in }
        }

        let expected = Tasting(
            id: "t-existing",
            wineId: wine.id,
            date: Date(timeIntervalSince1970: 2000),
            photoURLs: [u1],
            createdAt: Date(timeIntervalSince1970: 1500)
        )

        await store.send(.saveTapped) {
            $0.isSaving = true
            $0.errorMessage = nil
        }
        await store.receive(.saveResponse(.success(expected))) {
            $0.isSaving = false
        }
        await store.receive(.delegate(.saved(expected)))
    }

    /// 6. Cancel emits `.delegate(.cancelled)` with no side effects.
    func testCancelEmitsCancelledDelegate() async {
        let wine = Wine(producer: "Anything", vintage: 2020)

        let store = TestStore(initialState: TastingFormReducer.State(wine: wine, hid: "test-hid", uid: "test-uid")) {
            TastingFormReducer()
        }

        await store.send(.cancelTapped)
        await store.receive(.delegate(.cancelled))
    }
}
