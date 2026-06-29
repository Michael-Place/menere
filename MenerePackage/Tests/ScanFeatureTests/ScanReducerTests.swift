import BottleCardFeature
import CatalogClient
import ComposableArchitecture
import IdentifyClient
import WineDomain
import XCTest

@testable import ScanFeature

/// `TestStore` coverage for the M4 Phase 2 image-threading + progressive-reveal plumbing. Stubs
/// `\.identify` and `\.catalog` so the tests stay offline and deterministic.
@MainActor
final class ScanReducerTests: XCTestCase {
    /// `.useSampleTapped` captures the sample image, then identity → resolving → resolved keeps the
    /// image threaded the whole way through.
    func testUseSampleThreadsImageThroughToResolved() async {
        let candidate = WineCandidate(producer: "Château Margaux", name: "Grand Vin", vintage: 2015, confidence: 0.85)
        let wine = Wine(producer: "Château Margaux", name: "Grand Vin", vintage: 2015, type: .red, abv: 13.5)
        let sample = IdentifyFixtures.sampleLabelImageData

        let store = TestStore(initialState: ScanReducer.State()) {
            ScanReducer()
        } withDependencies: {
            $0.identify.identify = { _ in candidate }
            $0.catalog.resolve = { _ in wine }
        }

        await store.send(.useSampleTapped) {
            $0.capturedImageData = sample
            $0.status = .identifying
        }
        await store.receive(.identifyResponse(candidate)) {
            $0.status = .resolving(candidate)
        }
        await store.receive(.resolveResponse(wine)) {
            $0.status = .resolved(wine)
            $0.bottleCard = BottleCardFeature.State(wine: wine, imageData: sample, isResolving: false)
        }
        XCTAssertEqual(store.state.capturedImageData, sample, "captured image must persist through resolve")
    }

    /// `.imageCaptured(data)` stores that exact data and persists it through to `.resolved`.
    func testImageCapturedStoresExactDataThroughResolved() async {
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let candidate = WineCandidate(producer: "Ridge Vineyards", name: "Monte Bello", vintage: 2018)
        let wine = Wine(producer: "Ridge Vineyards", name: "Monte Bello", vintage: 2018, type: .red)

        let store = TestStore(initialState: ScanReducer.State()) {
            ScanReducer()
        } withDependencies: {
            $0.identify.identify = { received in
                XCTAssertEqual(received, data, "identify must receive the exact captured bytes")
                return candidate
            }
            $0.catalog.resolve = { _ in wine }
        }

        await store.send(.imageCaptured(data)) {
            $0.capturedImageData = data
            $0.status = .identifying
        }
        await store.receive(.identifyResponse(candidate)) {
            $0.status = .resolving(candidate)
        }
        await store.receive(.resolveResponse(wine)) {
            $0.status = .resolved(wine)
            $0.bottleCard = BottleCardFeature.State(wine: wine, imageData: data, isResolving: false)
        }
        XCTAssertEqual(store.state.capturedImageData, data)
    }

    /// Barcode scans carry no image; a resolve failure (insufficient identity) falls back to
    /// `.result(candidate)` without crashing, and no image is ever set.
    func testBarcodePathHasNoImageAndFallsBackToResult() async {
        let candidate = WineCandidate(barcode: "012345678905", confidence: 0.5, source: .barcode)

        let store = TestStore(initialState: ScanReducer.State()) {
            ScanReducer()
        } withDependencies: {
            $0.identify.identifyBarcode = { payload, _ in
                WineCandidate(barcode: payload, confidence: 0.5, source: .barcode)
            }
            $0.catalog.resolve = { _ in throw CatalogError.insufficientIdentity }
        }

        await store.send(.barcodeScanned("012345678905", "ean13")) {
            $0.status = .identifying
        }
        await store.receive(.identifyResponse(candidate)) {
            $0.status = .resolving(candidate)
        }
        await store.receive(\.resolveFailed) {
            $0.status = .result(candidate)
        }
        XCTAssertNil(store.state.capturedImageData, "barcode path must never set an image")
    }

    /// `.scanAgain` returns to a clean `.idle` state and clears any captured image.
    func testScanAgainResetsToIdleAndClearsImage() async {
        let resolvedWine = Wine(producer: "Anything", vintage: 2020)
        var initial = ScanReducer.State()
        initial.capturedImageData = Data([0xAA, 0xBB])
        initial.status = .resolved(resolvedWine)
        initial.bottleCard = BottleCardFeature.State(
            wine: resolvedWine,
            imageData: Data([0xAA, 0xBB]),
            isResolving: false
        )

        let store = TestStore(initialState: initial) {
            ScanReducer()
        }

        await store.send(.scanAgain) {
            $0.capturedImageData = nil
            $0.status = .idle
            $0.bottleCard = nil
        }
        XCTAssertNil(store.state.capturedImageData)
    }
}
