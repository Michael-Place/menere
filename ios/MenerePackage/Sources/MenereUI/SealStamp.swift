import SwiftUI

/// A celebratory stamp overlay — the "tucked into your cellar" flourish played when a bottle is
/// added. Reskinned from the old wax-seal to a light Bacán motif (a `bacanGreen` badge with a cream
/// check + marigold ring and a rounded caption chip) so it reads as the same playful family app.
/// Invisible at rest; replays a one-shot keyframe (scale overshoot + a slight rotation, like a sticker
/// slapping down) and fades out whenever `trigger` bumps. Pair with a `.successHaptic`.
///
/// Mount it once in an `.overlay` and drive it with a monotonic counter (e.g. the reducer's
/// `sealStamp`); the `keyframeAnimator` fires on each change and rests transparent in between.
public struct SealStamp: View {
    let trigger: Int

    public init(trigger: Int) {
        self.trigger = trigger
    }

    /// Animatable state the keyframe tracks drive.
    private struct Frame {
        var scale: Double = 0.4
        var rotation: Double = -16
        var opacity: Double = 0
    }

    public var body: some View {
        stamp
            .keyframeAnimator(initialValue: Frame(), trigger: trigger) { content, frame in
                content
                    .scaleEffect(frame.scale)
                    .rotationEffect(.degrees(frame.rotation))
                    .opacity(frame.opacity)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.14, duration: 0.30, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.18, spring: .snappy)
                    LinearKeyframe(1.0, duration: 0.62)
                    LinearKeyframe(0.96, duration: 0.30)
                }
                KeyframeTrack(\.rotation) {
                    SpringKeyframe(5, duration: 0.30, spring: .bouncy)
                    SpringKeyframe(0, duration: 0.18, spring: .snappy)
                    LinearKeyframe(0, duration: 0.92)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.18)
                    LinearKeyframe(1, duration: 0.80)
                    LinearKeyframe(0, duration: 0.42)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// A fixed warm cream for the check + caption text, pinned light in both appearances so it reads on
    /// the `bacanGreen` badge (the dynamic cream token would vanish in dark mode).
    private static var cream: Color { Color(uiColor: UIColor(hex: 0xF7F1E8)) }

    private var stamp: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.bacanGreen)
                Circle()
                    .strokeBorder(Color.marigold, lineWidth: 3)
                    .padding(7)
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(Self.cream)
            }
            .frame(width: 132, height: 132)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 7)

            Text("Tucked into your cellar")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.familySurface))
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
    }
}

#if DEBUG
private struct SealStampDemo: View {
    @State private var trigger = 0
    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            Button("Stamp it") { trigger += 1 }
                .buttonStyle(.borderedProminent)
            SealStamp(trigger: trigger)
        }
    }
}

#Preview("Wax seal") { SealStampDemo() }
#endif
