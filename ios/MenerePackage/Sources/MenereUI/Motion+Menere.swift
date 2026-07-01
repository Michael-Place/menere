import SwiftUI

public extension Animation {
    /// Brisk, crisp transition for most state changes.
    static let menereSnappy = Animation.snappy(duration: 0.32)
    /// Playful settle for celebratory moments (e.g. a resolved card revealing).
    static let menereBouncy = Animation.bouncy(duration: 0.45, extraBounce: 0.1)
}
