import SwiftUI

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
