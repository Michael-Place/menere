import SwiftUI
import UIKit

// The "watering feels great" kit (delight micro-interaction). Three reusable pieces you compose on a
// water / care-done button, all keyed to one monotonic `trigger` you bump on each successful tap:
//
//   • `WaterBurst`            — a fling of droplets + an expanding ripple (mount as an overlay).
//   • `.waterCelebration(…)`  — that burst PLUS a rotating cheerful micro-copy toast, in one modifier.
//   • `.plantBounce(trigger:)`— a happy spring bounce for the plant's row/thumbnail ("it's happy").
//   • `WaterGlyph(trigger:)`  — the button icon: a droplet that morphs to a checkmark on completion.
//
// Pair with `MenereHaptics.water()` (fired from the button action) for the core dopamine. Everything
// is FAST (~0.75s), non-blocking (never intercepts touches), interruptible (fast repeat taps restart
// cleanly), and Reduce-Motion aware (physics/bounce skipped; glyph swap + haptic preserved).

// MARK: - Water palette

private extension Color {
    /// The droplet/ripple palette — cool sky blues with a botanical-green wink and a white sparkle.
    static let waterPalette: [Color] = [
        .sky,
        Color(uiColor: UIColor(hex: 0x8FD0F2)),   // pale sky highlight
        Color(uiColor: UIColor(hex: 0x2E7FB8)),   // deeper water
        .bacanGreen,                              // a leafy wink
        Color(uiColor: UIColor(hex: 0xEAF6FD)),   // near-white splash sparkle
    ]
}

// MARK: - WaterBurst (droplets + ripple)

/// A quick, joyful burst of water for the "I watered a plant" moment: a handful of small blue/sky
/// DROPLETS fling outward from the tapped button and fall under gravity, while a RIPPLE ring expands
/// from the same point — like a drop hitting a pool. ~0.75s, then idle (a paused `TimelineView`, so it
/// costs nothing at rest).
///
/// Drive with a monotonic `trigger` (bump on each water tap). Mount as an overlay so its center
/// anchors the burst; give it a frame larger than the button so droplets aren't clipped. Non-blocking
/// and interruptible: a `.task(id:)` owns one burst, so fast repeats restart instead of stacking.
/// Respects `accessibilityReduceMotion` (the physics are skipped entirely).
public struct WaterBurst: View {
    private let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var droplets: [Droplet] = []
    @State private var startDate: Date?

    private let duration: TimeInterval = 0.75
    private let gravity: Double = 900 // px/s²

    public init(trigger: Int) { self.trigger = trigger }

    public var body: some View {
        TimelineView(.animation(paused: startDate == nil)) { timeline in
            Canvas { context, size in
                guard let start = startDate else { return }
                draw(at: timeline.date.timeIntervalSince(start), size: size, context: &context)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: trigger) {
            guard trigger > 0, !reduceMotion else { return }
            droplets = Self.makeDroplets(count: 14)
            startDate = .now
            do {
                try await Task.sleep(for: .seconds(duration + 0.05))
            } catch {
                return // cancelled by a newer trigger — that run owns the reset
            }
            startDate = nil
            droplets = []
        }
    }

    private func draw(at t: TimeInterval, size: CGSize, context: inout GraphicsContext) {
        guard t <= duration else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        drawRipples(at: t, center: center, context: &context)
        drawDroplets(at: t, center: center, context: &context)
    }

    // Two staggered rings expanding + fading from the tap point — a drop hitting a pool.
    private func drawRipples(at t: TimeInterval, center: CGPoint, context: inout GraphicsContext) {
        for ring in 0..<2 {
            let delay = Double(ring) * 0.11
            let rt = t - delay
            guard rt >= 0 else { continue }
            let p = min(1, rt / (duration - delay))
            let radius = 6 + p * 34
            let opacity = (1 - p) * 0.55
            guard opacity > 0.01 else { continue }
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.sky.opacity(opacity)),
                lineWidth: 2.2 * (1 - p * 0.6)
            )
        }
    }

    private func drawDroplets(at t: TimeInterval, center: CGPoint, context: inout GraphicsContext) {
        for d in droplets {
            let tp = t - d.delay
            guard tp >= 0 else { continue }
            let x = center.x + d.vx * tp
            let vy = d.vy0 + gravity * tp
            let y = center.y + d.vy0 * tp + 0.5 * gravity * tp * tp
            let life = min(1, tp / (duration - d.delay))
            // Grow briefly, then fade as they fall.
            let opacity = life < 0.75 ? 1.0 : max(0, 1 - (life - 0.75) / 0.25)
            guard opacity > 0.01 else { continue }
            let heading = atan2(vy, d.vx) + .pi / 2 // teardrop tip points along travel
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: x, y: y)
                layer.rotate(by: .radians(heading))
                layer.fill(Self.teardrop(width: d.width, height: d.height), with: .color(d.color))
                // A tiny specular dot for a wet, glassy read.
                let dot = CGRect(x: -d.width * 0.16, y: -d.height * 0.18, width: d.width * 0.28, height: d.width * 0.28)
                layer.fill(Path(ellipseIn: dot), with: .color(.white.opacity(0.55 * opacity)))
            }
        }
    }

    /// A small upward-pointing teardrop centered on the origin.
    private static func teardrop(width w: Double, height h: Double) -> Path {
        var path = Path()
        let tip = CGPoint(x: 0, y: -h / 2)
        let bulbCenterY = h / 2 - w / 2
        path.move(to: tip)
        path.addQuadCurve(to: CGPoint(x: w / 2, y: bulbCenterY), control: CGPoint(x: w / 2, y: -h / 8))
        path.addArc(center: CGPoint(x: 0, y: bulbCenterY), radius: w / 2,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addQuadCurve(to: tip, control: CGPoint(x: -w / 2, y: -h / 8))
        return path
    }

    // MARK: Particles

    private struct Droplet: Identifiable {
        let id = UUID()
        let vx: Double     // horizontal velocity, px/s
        let vy0: Double    // initial vertical velocity, px/s (negative = up)
        let width: Double
        let height: Double
        let color: Color
        let delay: Double
    }

    private static func makeDroplets(count: Int) -> [Droplet] {
        (0..<count).map { _ in
            // Launch up-and-out (a fountain), then gravity brings them down. Angle across the upper
            // hemisphere for a splash that arcs rather than raining straight down.
            let angle = Double.random(in: (.pi * 0.08)...(.pi * 0.92)) // 0…π from +x, arcing upward
            let speed = Double.random(in: 70...190)
            let w = Double.random(in: 5...8)
            return Droplet(
                vx: cos(angle) * speed,       // cos spans + and − → splashes left and right
                vy0: -sin(angle) * speed,     // negative = launch upward
                width: w,
                height: w * Double.random(in: 1.7...2.2),
                color: Color.waterPalette.randomElement() ?? .sky,
                delay: .random(in: 0...0.06)
            )
        }
    }
}

// MARK: - waterCelebration modifier (burst + micro-copy toast)

/// The rotating cheerful lines shown in the little toast — warm, witty, first-name-the-plant voice.
/// `{PlantName}` is filled in when a name is provided.
private let waterQuips: [String] = [
    "Slurp! 💧",
    "Ahh, refreshing 🌿",
    "{PlantName} says thanks!",
    "Hydrated ✨",
    "Glug glug 💦",
]

private struct WaterCelebration: ViewModifier {
    let trigger: Int
    let plantName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastText: String?
    @State private var toastNonce = 0

    func body(content: Content) -> some View {
        content
            // Droplets + ripple, on a frame larger than the button so fast droplets don't clip.
            .overlay {
                WaterBurst(trigger: trigger)
                    .frame(width: 170, height: 170)
                    .allowsHitTesting(false)
            }
            // The cheerful micro-copy, floating just above the button. Anchored trailing so a wide line
            // ("{Plant} says thanks!") grows leftward and can't run off the right screen edge.
            .overlay(alignment: .topTrailing) {
                if let toastText {
                    Text(toastText)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous).fill(Color.sky)
                                .shadow(color: .sky.opacity(0.35), radius: 6, y: 2)
                        )
                        .fixedSize()
                        .offset(y: -34)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .id(toastNonce)
                        .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0, !reduceMotion else { return }
                let idx = (newValue - 1) % waterQuips.count
                let name = (plantName?.split(separator: " ").first).map(String.init) ?? "It"
                toastNonce += 1
                let nonce = toastNonce
                withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) {
                    toastText = waterQuips[idx].replacingOccurrences(of: "{PlantName}", with: name)
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard nonce == toastNonce else { return } // a newer tap owns the toast now
                    withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
                }
            }
    }
}

// MARK: - plantBounce modifier

/// A happy little spring BOUNCE for a plant's row or thumbnail on watering — it scales up ~8% with a
/// slight sway and settles, "the plant perking up." Keyed to the same `trigger` as the burst; plays
/// only when the trigger advances. Skipped under Reduce Motion (renders at rest).
private struct PlantBounce: ViewModifier {
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Frame {
        var scale: Double = 1
        var rotation: Double = 0
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .keyframeAnimator(initialValue: Frame(), trigger: trigger) { view, frame in
                    view
                        .scaleEffect(frame.scale, anchor: .bottom)
                        .rotationEffect(.degrees(frame.rotation), anchor: .bottom)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        SpringKeyframe(1.08, duration: 0.20, spring: .bouncy)
                        SpringKeyframe(1.0, duration: 0.40, spring: .bouncy)
                    }
                    KeyframeTrack(\.rotation) {
                        CubicKeyframe(-2.5, duration: 0.12)
                        CubicKeyframe(2.0, duration: 0.16)
                        SpringKeyframe(0, duration: 0.32, spring: .snappy)
                    }
                }
        }
    }
}

// MARK: - WaterGlyph (droplet → checkmark morph)

/// The water button's icon: a droplet at rest that MORPHS to a checkmark for a beat when watering
/// completes, then settles back — the little "done!" wink. Uses a symbol-replace content transition,
/// so it stays gentle and works under Reduce Motion (this glyph swap IS the reduced-motion payoff).
public struct WaterGlyph: View {
    private let trigger: Int
    private let size: CGFloat
    private let restSymbol: String
    private let tint: Color

    @State private var showCheck = false

    public init(trigger: Int, size: CGFloat = 20, restSymbol: String = "drop.fill", tint: Color = .bacanGreen) {
        self.trigger = trigger
        self.size = size
        self.restSymbol = restSymbol
        self.tint = tint
    }

    public var body: some View {
        Image(systemName: showCheck ? "checkmark.circle.fill" : restSymbol)
            .font(.system(size: size))
            .foregroundStyle(showCheck ? Color.bacanGreen : tint)
            .contentTransition(.symbolEffect(.replace))
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0 else { return }
                withAnimation(.snappy) { showCheck = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(1100))
                    withAnimation(.easeOut(duration: 0.3)) { showCheck = false }
                }
            }
    }
}

// MARK: - View sugar

public extension View {
    /// Play the full water celebration — droplet burst + ripple + a rotating cheerful toast — over
    /// this button on each advance of `trigger`. Pass the `plantName` so the toast can say
    /// "{first name} says thanks!". Pair with `MenereHaptics.water()` in the button action and
    /// `WaterGlyph` for the icon. See ``WaterBurst``.
    func waterCelebration(trigger: Int, plantName: String? = nil) -> some View {
        modifier(WaterCelebration(trigger: trigger, plantName: plantName))
    }

    /// A happy spring bounce for a plant's row/thumbnail on watering. Drive with the same `trigger`
    /// as `waterCelebration`. Skipped under Reduce Motion. See ``PlantBounce``.
    func plantBounce(trigger: Int) -> some View {
        modifier(PlantBounce(trigger: trigger))
    }
}

#if DEBUG
private struct WaterCelebrationDemo: View {
    @State private var trigger = 0
    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.bacanGreen.opacity(0.15))
                    Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen)
                }
                .frame(width: 44, height: 44)
                .plantBounce(trigger: trigger)

                Text("Monstera").font(.system(.body, design: .rounded))
                Spacer()

                Button {
                    trigger += 1
                    MenereHaptics.water()
                } label: {
                    WaterGlyph(trigger: trigger, size: 22, tint: .sky)
                }
                .buttonStyle(.pressable)
                .waterCelebration(trigger: trigger, plantName: "Monstera Deliciosa")
            }
            .padding(24)
            .background(Capsule().fill(Color.familySurface))
            .padding()
        }
    }
}

#Preview("Water celebration") { WaterCelebrationDemo() }
#endif
