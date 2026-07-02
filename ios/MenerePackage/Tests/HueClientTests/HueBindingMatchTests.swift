import FamilyDomain
import Foundation
import Testing

@testable import HueClient

/// Locks the P12-C2 re-pair name-matching rule (scene auto-bind + sensor-label carry-forward). Pure
/// functions of names only — the meanings that must survive a bridge's death.
struct HueBindingMatchTests {
    private let cozyBedtime = HueScene(id: "s-bed", name: "Cozy Bedtime", groupId: "3")
    private let dinnerTime = HueScene(id: "s-din", name: "Dinner time", groupId: "1")
    private let relax = HueScene(id: "s-relax", name: "Relax", groupId: "2")

    @Test func bedtimeMatchesOnLabelWord() {
        let match = HueBindingMatch.matchScene(key: "bedtime", label: "Bedtime", in: [cozyBedtime, dinnerTime])
        #expect(match?.id == "s-bed")
    }

    @Test func dinnerMatchesOnKeyEvenWhenLabelDiffers() {
        // "Dinner time" contains neither the full label "Dinner's ready" nor vice versa, but it
        // contains the ritual key "dinner".
        let match = HueBindingMatch.matchScene(key: "dinner", label: "Dinner's ready", in: [dinnerTime, relax])
        #expect(match?.id == "s-din")
    }

    @Test func noMatchLeavesNil() {
        let match = HueBindingMatch.matchScene(key: "bedtime", label: "Bedtime", in: [dinnerTime, relax])
        #expect(match == nil)
    }

    @Test func sensorLabelCarriesForwardByExactName() {
        let old = HueConfig(
            bridgeId: "old", bridgeIP: "1.1.1.1", applicationKey: "k",
            sensorLabels: ["old-id": "Oliver's room"],
            sensorNames: ["old-id": "Nursery sensor"]
        )
        #expect(HueBindingMatch.prefillSensorLabel(for: "Nursery sensor", from: old) == "Oliver's room")
    }

    @Test func sensorLabelCarriesForwardBySubstring() {
        let old = HueConfig(
            bridgeId: "old", bridgeIP: "1.1.1.1", applicationKey: "k",
            sensorLabels: ["old-id": "Famfis"],
            sensorNames: ["old-id": "Hue motion sensor"]
        )
        // New bridge renames it slightly — substring match still carries the label.
        #expect(HueBindingMatch.prefillSensorLabel(for: "Hue motion sensor 1", from: old) == "Famfis")
    }

    @Test func sensorLabelEmptyWhenNothingToCarry() {
        #expect(HueBindingMatch.prefillSensorLabel(for: "Anything", from: nil) == "")
    }
}
