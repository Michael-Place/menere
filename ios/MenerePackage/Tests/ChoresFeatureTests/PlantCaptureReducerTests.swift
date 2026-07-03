import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import StorageClient
import UserDomain
import XCTest

@testable import ChoresFeature

/// `TestStore` coverage for the P9.1 Planta-inspired capture wizard: the full happy walk
/// (photo → identify → nickname → home → watering → welcome) builds a `CareItem` with the right
/// fields, plus the watering-anchor math and the AI-light mapping.
@MainActor
final class PlantCaptureReducerTests: XCTestCase {

    private let monstera = PlantIdentification(
        commonName: "Monstera",
        latinName: "Monstera deliciosa",
        confidence: "high",
        waterIntervalDays: 10,
        light: "Bright indirect",
        careNotes: "Water when the top inch is dry."
    )

    func testFullWalkBuildsCorrectCareItem() async throws {
        try await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", displayName: "Migueluh", householdId: "hid-1") }

            let saved = LockIsolated<[CareItem]>([])
            let photo = Data([0x1, 0x2, 0x3])
            let ident = monstera

            let store = TestStore(
                initialState: PlantCaptureReducer.State(itemID: "plant-1", existingLocations: ["Sunroom"])
            ) {
                PlantCaptureReducer()
            } withDependencies: {
                $0.plants.identify = { _ in ident }
                $0.storage.uploadCarePhoto = { hid, id, _ in "households/\(hid)/care/\(id)/photo.jpg" }
                $0.persistence.saveCareItem = { _, i in saved.withValue { $0.append(i) } }
                $0.dismiss = DismissEffect {}
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            // 1) Photo → advances to identify + kicks the AI call.
            await store.send(.photoPicked(photo))
            await store.receive(.identifyStart)
            await store.receive(.identifyResponse(ident)) {
                $0.isIdentifying = false
                $0.species = "Monstera"
                $0.speciesLatin = "Monstera deliciosa"
                $0.careNotes = "Bright indirect light. Water when the top inch is dry."
                $0.waterIntervalDays = 10
                $0.lightLevel = "Bright indirect"
            }

            // 2) Reveal → nickname (prefilled with the common name).
            await store.send(.nextTapped) {
                $0.nickname = "Monstera"
                $0.step = .nickname
            }
            await store.send(.binding(.set(\.nickname, "Monty"))) { $0.nickname = "Monty" }

            // 3) → Home: pick a location + light.
            await store.send(.nextTapped) { $0.step = .home }
            await store.send(.locationChipTapped("Kitchen")) { $0.location = "Kitchen" }
            await store.send(.lightTapped("Medium")) { $0.lightLevel = "Medium" }

            // 4) → Watering anchor: "A few days ago" (-3d).
            await store.send(.nextTapped) { $0.step = .watering }
            await store.send(.anchorTapped(.fewDays)) { $0.wateringAnchor = .fewDays }

            // 5) Create → save → welcome beat.
            await store.send(.createTapped) { $0.isSaving = true }
            await store.receive(.created) {
                $0.isSaving = false
                $0.step = .welcome
            }

            // The persisted plant carries every wizard field.
            let plant = saved.value.first
            XCTAssertEqual(saved.value.count, 1)
            XCTAssertEqual(plant?.name, "Monty")
            XCTAssertEqual(plant?.kind, .plant)
            XCTAssertEqual(plant?.species, "Monstera")
            XCTAssertEqual(plant?.speciesLatin, "Monstera deliciosa")
            XCTAssertEqual(plant?.lightLevel, "Medium")
            XCTAssertEqual(plant?.location, "Kitchen")
            XCTAssertEqual(plant?.photoPath, "households/hid-1/care/plant-1/photo.jpg")
            XCTAssertEqual(plant?.tasks.first?.title, "Water")
            XCTAssertEqual(plant?.tasks.first?.intervalDays, 10)          // AI cadence
            // Anchored -3d ⇒ with the 10-day interval, next water is ~7 days out.
            let last = try XCTUnwrap(plant?.tasks.first?.lastDoneAt)
            let days = Calendar.current.dateComponents([.day], from: last, to: Date()).day
            XCTAssertEqual(days, 3)
        }
    }

    /// A low-confidence identify degrades to a warm no-fill (manual name), never trapping.
    func testLowConfidenceIdentifyDegradesGracefully() async {
        await withDependencies {
            $0.defaultFileStorage = .inMemory
        } operation: {
            @Shared(.user) var user
            $user.withLock { $0 = User(id: "uid-1", householdId: "hid-1") }

            let lowConf = PlantIdentification(commonName: "Fern?", confidence: "low")
            let store = TestStore(initialState: PlantCaptureReducer.State(itemID: "p2")) {
                PlantCaptureReducer()
            } withDependencies: {
                $0.plants.identify = { _ in lowConf }
                $0.dismiss = DismissEffect {}
            }
            store.exhaustivity = .off(showSkippedAssertions: false)

            await store.send(.photoPicked(Data([0x9])))
            await store.receive(.identifyStart)
            await store.receive(.identifyResponse(lowConf)) {
                $0.isIdentifying = false
                $0.identifyFailed = true
                $0.identification = lowConf
                $0.species = ""            // no fill
            }
        }
    }

    func testWaterAnchorMath() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 12))!
        XCTAssertEqual(PlantCaptureReducer.WaterAnchor.today.lastDoneAt(now: now), now)
        XCTAssertEqual(
            PlantCaptureReducer.WaterAnchor.fewDays.lastDoneAt(now: now),
            Calendar.current.date(byAdding: .day, value: -3, to: now)
        )
        XCTAssertEqual(
            PlantCaptureReducer.WaterAnchor.overWeek.lastDoneAt(now: now),
            Calendar.current.date(byAdding: .day, value: -8, to: now)
        )
        XCTAssertNil(PlantCaptureReducer.WaterAnchor.noIdea.lastDoneAt(now: now))
    }

    func testAILightMapping() {
        XCTAssertEqual(PlantCaptureReducer.matchLight("bright, indirect light"), "Bright indirect")
        XCTAssertEqual(PlantCaptureReducer.matchLight("full sun"), "Direct sun")
        XCTAssertEqual(PlantCaptureReducer.matchLight("low light / shade"), "Low")
        XCTAssertEqual(PlantCaptureReducer.matchLight("medium, partial"), "Medium")
        XCTAssertNil(PlantCaptureReducer.matchLight("who knows"))
    }
}
