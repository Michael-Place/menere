import SwiftUI

/// The plant-care counterpart to ``StickerSlap``: when a plant task is marked done (watered, fed,
/// misted) the affordance glyph *unfurls* — it curls in for a beat, then springs open with a little
/// overshoot and a soft green ripple, like a new leaf opening. Softer and more organic than the
/// sticker slap's punchy pop, which fits the calmer "I watered the plant" moment.
///
/// Apply to the mark-done glyph itself:
/// `Image(systemName: "drop.fill").leafUnfurl(isOn: watered, color: .bacanGreen)`.
/// Plays only on the off→on transition; the un-mark (if any) is an instant, quiet swap.
///
/// Interruptible & non-blocking, mirroring ``StickerSlap``: a one-shot `keyframeAnimator` keyed to a
/// monotonic counter that only advances on off→on, so rapid toggling restarts from rest rather than
/// stacking. Respects `accessibilityReduceMotion` (visual skipped, soft haptic preserved).
public struct LeafUnfurl: ViewModifier {
    let isOn: Bool
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Advances only on off→on, so it drives the unfurl but never the un-mark.
    @State private var unfurlCount = 0

    private struct Frame {
        var scale: Double = 1
        var rotation: Double = 0
        var rippleScale: Double = 0
        var rippleOpacity: Double = 0
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if reduceMotion {
            content
                .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: unfurlCount)
                .onChange(of: isOn) { _, nowOn in if nowOn { unfurlCount += 1 } }
        } else {
            content
                .keyframeAnimator(initialValue: Frame(), trigger: unfurlCount) { view, frame in
                    view
                        .overlay {
                            if let color, frame.rippleOpacity > 0 {
                                Circle()
                                    .stroke(color, lineWidth: 2)
                                    .scaleEffect(frame.rippleScale)
                                    .opacity(frame.rippleOpacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(frame.scale)
                        .rotationEffect(.degrees(frame.rotation))
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(0.72, duration: 0.10)                     // curl in
                        SpringKeyframe(1.14, duration: 0.30, spring: .bouncy)   // unfurl w/ overshoot
                        SpringKeyframe(1.0, duration: 0.30, spring: .snappy)    // settle
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-30, duration: 0.10)                      // furled tilt
                        SpringKeyframe(7, duration: 0.32, spring: .bouncy)      // spring open
                        SpringKeyframe(0, duration: 0.28, spring: .snappy)
                    }
                    KeyframeTrack(\.rippleScale) {
                        CubicKeyframe(2.1, duration: 0.58)
                    }
                    KeyframeTrack(\.rippleOpacity) {
                        LinearKeyframe(0.45, duration: 0.06)
                        LinearKeyframe(0.0, duration: 0.52)
                    }
                }
                .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.8), trigger: unfurlCount)
                .onChange(of: isOn) { _, nowOn in if nowOn { unfurlCount += 1 } }
        }
    }
}

public extension View {
    /// Play the leaf-unfurl celebration on the off→on transition of `isOn` — the plant-care
    /// counterpart to ``stickerSlap(isOn:color:)``. Pass a `color` for the soft ripple. See
    /// ``LeafUnfurl``.
    func leafUnfurl(isOn: Bool, color: Color? = nil) -> some View {
        modifier(LeafUnfurl(isOn: isOn, color: color))
    }
}

#if DEBUG
private struct LeafUnfurlDemo: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            Button { on.toggle() } label: {
                Image(systemName: "drop.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.bacanGreen)
                    .leafUnfurl(isOn: on, color: .bacanGreen)
            }
            .buttonStyle(.pressable)
        }
    }
}

#Preview("Leaf unfurl") { LeafUnfurlDemo() }
#endif
