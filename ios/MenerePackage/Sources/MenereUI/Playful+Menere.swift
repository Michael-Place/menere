import SwiftUI

/// Springy scale-on-press feedback for family-surface controls — check toggles, primary buttons.
/// Cheap, non-blocking, and interruptible; settles with `.menereSnappy`. Skipped under
/// `accessibilityReduceMotion` so presses stay instant.
///
/// `Button(...) { ... }.buttonStyle(.pressable)` — or `.pressable(scale:)` to tune the squish.
public struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.88

    public init(scale: CGFloat = 0.88) { self.scale = scale }

    public func makeBody(configuration: Configuration) -> some View {
        Squish(configuration: configuration, scale: scale)
    }

    private struct Squish: View {
        let configuration: Configuration
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect((configuration.isPressed && !reduceMotion) ? scale : 1)
                .animation(.menereSnappy, value: configuration.isPressed)
        }
    }
}

public extension ButtonStyle where Self == PressableButtonStyle {
    /// Springy scale-on-press feedback. See ``PressableButtonStyle``.
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
    static func pressable(scale: CGFloat) -> PressableButtonStyle { PressableButtonStyle(scale: scale) }
}

/// A one-shot symbol bounce played when the view appears — a little "here I am" wink for
/// affordances like "Add reward" / "New list". No-op under `accessibilityReduceMotion`.
public struct AppearBounce: ViewModifier {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
            .onAppear { if !reduceMotion { appeared = true } }
    }
}

public extension View {
    /// Bounce this SF Symbol once when it appears. See ``AppearBounce``.
    func appearBounce() -> some View { modifier(AppearBounce()) }
}
