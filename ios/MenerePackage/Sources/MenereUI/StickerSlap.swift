import SwiftUI

/// The marquee family-surface moment: when something is checked off (a chore, a list item), the
/// check indicator lands like a sticker being slapped on — it pops oversized, settles with a bouncy
/// spring and a little rotation wobble, punches out a quick color ring, and fires a rigid impact
/// haptic. Oliver (3) watches chores get checked off; this is the payoff.
///
/// Apply to the check indicator itself: `Image(...).stickerSlap(isOn: chore.isCompleted, color: .bacanGreen)`.
/// The celebration plays only on the off→on transition. **Un**-checking is a plain, instant swap — no
/// celebration — matching the "completing is the moment" intent.
///
/// Interruptible & non-blocking: each slap is a one-shot `keyframeAnimator` keyed to a monotonic
/// counter that only advances when `isOn` becomes true, so rapid on/off/on toggling never queues or
/// stacks animations — the newest slap simply restarts from rest. Respects
/// `accessibilityReduceMotion`: the visual celebration is skipped (state change stays instant) while
/// the haptic — not a motion effect — is preserved.
public struct StickerSlap: ViewModifier {
    let isOn: Bool
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Advances only on off→on, so it drives the celebration but never the un-check.
    @State private var slapCount = 0

    private struct Frame {
        var scale: Double = 1
        var rotation: Double = 0
        var ringScale: Double = 0
        var ringOpacity: Double = 0
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if reduceMotion {
            content
                .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: slapCount)
                .onChange(of: isOn) { _, nowOn in if nowOn { slapCount += 1 } }
        } else {
            content
                .keyframeAnimator(initialValue: Frame(), trigger: slapCount) { view, frame in
                    view
                        .overlay {
                            if let color, frame.ringOpacity > 0 {
                                Circle()
                                    .stroke(color, lineWidth: 2.5)
                                    .scaleEffect(frame.ringScale)
                                    .opacity(frame.ringOpacity)
                                    .allowsHitTesting(false)
                            }
                        }
                        .scaleEffect(frame.scale)
                        .rotationEffect(.degrees(frame.rotation))
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        CubicKeyframe(1.7, duration: 0.09)          // pop oversized
                        SpringKeyframe(1.0, duration: 0.5, spring: .bouncy)  // slap-and-settle
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-11, duration: 0.09)
                        CubicKeyframe(8, duration: 0.12)
                        SpringKeyframe(0, duration: 0.34, spring: .snappy)
                    }
                    KeyframeTrack(\.ringScale) {
                        CubicKeyframe(2.3, duration: 0.46)
                    }
                    KeyframeTrack(\.ringOpacity) {
                        LinearKeyframe(0.5, duration: 0.03)
                        LinearKeyframe(0.0, duration: 0.43)
                    }
                }
                .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.9), trigger: slapCount)
                .onChange(of: isOn) { _, nowOn in if nowOn { slapCount += 1 } }
        }
    }
}

public extension View {
    /// Play the sticker-slap celebration on the off→on transition of `isOn`. Pass a `color` to punch
    /// out a matching pop-ring on impact. See ``StickerSlap``.
    func stickerSlap(isOn: Bool, color: Color? = nil) -> some View {
        modifier(StickerSlap(isOn: isOn, color: color))
    }
}

#if DEBUG
private struct StickerSlapDemo: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            Button { on.toggle() } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 44))
                    .foregroundStyle(on ? Color.bacanGreen : Color.inkSoft)
                    .stickerSlap(isOn: on, color: .bacanGreen)
            }
            .buttonStyle(.pressable)
        }
    }
}

#Preview("Sticker slap") { StickerSlapDemo() }
#endif
