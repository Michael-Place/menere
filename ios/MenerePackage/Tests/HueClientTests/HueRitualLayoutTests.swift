import FamilyDomain
import Foundation
import Testing

@testable import HueClient

/// Locks the shipped evening-prominence rule for the Today "house" ritual buttons. Pure function of
/// the clock + meal plan — no UI/network — so these assertions fully pin the P12-C1 behavior.
struct HueRitualLayoutTests {
    private let bedtime = HueRitual(key: "bedtime", label: "Bedtime", sceneId: "b", groupId: "3")
    private let dinner = HueRitual(key: "dinner", label: "Dinner's ready", sceneId: "d", groupId: "1")

    /// Fixed local dates for a deterministic clock.
    private func date(hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 2; c.hour = hour; c.minute = 0
        return Calendar.current.date(from: c)!
    }

    @Test func afternoonBedtimeSubduedAndSecond() {
        // 2pm, eating out → Bedtime subdued + second; Dinner subdued + first (config order).
        let result = HueRitualLayout.ordered(
            rituals: [dinner, bedtime], now: date(hour: 14), homeCookedDinner: false
        )
        #expect(result.map(\.ritual.key) == ["dinner", "bedtime"])
        #expect(result.first(where: { $0.ritual.key == "bedtime" })?.isProminent == false)
    }

    @Test func eveningBedtimeProminentAndFirst() {
        // 7pm → Bedtime forced to front and filled, regardless of config order.
        let result = HueRitualLayout.ordered(
            rituals: [dinner, bedtime], now: date(hour: 19), homeCookedDinner: false
        )
        #expect(result.first?.ritual.key == "bedtime")
        #expect(result.first?.isProminent == true)
    }

    @Test func dinnerProminentWhenHomeCooked() {
        // Home-cooked tonight → Dinner filled even in the afternoon; Bedtime still subdued.
        let result = HueRitualLayout.ordered(
            rituals: [bedtime, dinner], now: date(hour: 14), homeCookedDinner: true
        )
        #expect(result.first(where: { $0.ritual.key == "dinner" })?.isProminent == true)
        #expect(result.first(where: { $0.ritual.key == "bedtime" })?.isProminent == false)
        // Prominent (dinner) sorts ahead of subdued (bedtime) before 18:00.
        #expect(result.first?.ritual.key == "dinner")
    }

    @Test func eveningBoundaryIs1800() {
        #expect(HueRitualLayout.isEvening(date(hour: 17)) == false)
        #expect(HueRitualLayout.isEvening(date(hour: 18)) == true)
    }
}
