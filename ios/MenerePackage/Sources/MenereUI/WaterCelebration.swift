import SwiftUI
import UIKit

// The WATER flavor of the CelebrationKit (see `CelebrationKit.swift`): a fling of DROPLETS + an
// expanding RIPPLE, "a drop hitting a pool," for the plant-watering moment. `CelebrationBurst`
// composes this in for the `.water` style; the kit's other styles (leaf / earth / paw / wrench /
// generic) are emoji-particle siblings. Kept in its own file because its bespoke teardrop + ripple
// physics are distinct from the shared emoji burst.
//
// Drive with one monotonic `trigger` (bump on each water tap). FAST (~0.75s), non-blocking (never
// intercepts touches), interruptible (fast repeat taps restart cleanly), Reduce-Motion aware
// (physics skipped entirely). See `CelebrationKit.swift` for the public API you actually call
// (`.careCelebration`, `CelebrationGlyph`, `.careBounce`) and the D0 water back-compat wrappers.

// MARK: - Water palette

extension Color {
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
