import SwiftUI
import UIKit

/// Thin, consistent wrappers over `.sensoryFeedback` so haptic intent reads clearly at call sites.
public extension View {
    func successHaptic<T: Equatable>(_ trigger: T) -> some View {
        sensoryFeedback(.success, trigger: trigger)
    }

    func selectionHaptic<T: Equatable>(_ trigger: T) -> some View {
        sensoryFeedback(.selection, trigger: trigger)
    }

    func impactHaptic<T: Equatable>(_ trigger: T) -> some View {
        sensoryFeedback(.impact, trigger: trigger)
    }

    func errorHaptic<T: Equatable>(_ trigger: T) -> some View {
        sensoryFeedback(.error, trigger: trigger)
    }
}

/// Imperative haptics for "the tap itself" moments — fired straight from a button's action closure,
/// where a declarative `.sensoryFeedback(trigger:)` is awkward (the state that would drive it changes
/// in the same synchronous handler). Wraps `UIKit`'s feedback generators directly.
///
/// **Device only:** the iOS Simulator has no Taptic Engine, so none of these are perceptible there —
/// they are wired correctly but must be felt on real hardware.
public enum MenereHaptics {
    /// The core watering dopamine hit: a light impact the instant the droplet is tapped, then a
    /// `.success` notification a beat later as the celebration lands — a satisfying "tap … *plip!*"
    /// two-part sequence. Call from the water/care-done button's action.
    public static func water() {
        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.prepare()
        impact.impactOccurred(intensity: 0.9)
        // A short beat later, the "it landed" success buzz — reads as the water hitting the soil.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            let notify = UINotificationFeedbackGenerator()
            notify.notificationOccurred(.success)
        }
    }

    /// A single soft impact — the "press" acknowledgement, for spots where the full success sequence
    /// would be too much (e.g. a batch action that already has its own confirmation).
    public static func softTap() {
        let impact = UIImpactFeedbackGenerator(style: .soft)
        impact.impactOccurred(intensity: 0.7)
    }
}
