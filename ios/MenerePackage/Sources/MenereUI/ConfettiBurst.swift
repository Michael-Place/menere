import SwiftUI
import UIKit

/// A one-shot, full-width confetti celebration whose palette is derived from a single base color —
/// on the Chores leaderboard it rains in the color of the member who just leveled up. Drop it in an
/// overlay and drive it with a monotonic `trigger`; each bump replays ~1.8s of falling, spinning
/// paper, then goes idle (costs nothing at rest).
///
/// Interruptible & non-blocking: a `.task(id: trigger)` owns one burst, so re-triggering mid-flight
/// cancels and restarts cleanly — completing five chores fast never stacks five bursts. It never
/// intercepts touches. Respects `accessibilityReduceMotion` (the celebration is skipped entirely).
///
/// Pure SwiftUI: a `TimelineView(.animation)` (paused while idle, so it costs nothing at rest) drives
/// a `Canvas` that draws the falling, spinning paper. No CAEmitterLayer, no dependencies. Reused by
/// the Today dashboard (P6) and wherever a member-colored celebration is wanted.
public struct ConfettiBurst: View {
    private let color: Color
    private let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pieces: [Piece] = []
    @State private var startDate: Date?

    private let duration: TimeInterval = 1.8

    public init(color: Color, trigger: Int) {
        self.color = color
        self.trigger = trigger
    }

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
            pieces = Self.makePieces(count: 110, palette: Self.palette(from: color))
            startDate = .now
            do {
                try await Task.sleep(for: .seconds(duration + 0.1))
            } catch {
                return // cancelled by a newer trigger — that run owns the reset
            }
            startDate = nil
            pieces = []
        }
    }

    private func draw(at t: TimeInterval, size: CGSize, context: inout GraphicsContext) {
        guard t <= duration else { return }
        let g = 300.0 // px/s²
        for piece in pieces {
            let tp = t - piece.delay
            guard tp >= 0 else { continue }
            let x = piece.xFraction * size.width + piece.vx * tp + sin(tp * piece.wobble) * 12
            let y = piece.startYFraction * size.height + piece.vy0 * tp + 0.5 * g * tp * tp
            guard y < size.height + 40 else { continue }
            let life = min(1, tp / (duration - piece.delay))
            let opacity = life < 0.7 ? 1.0 : max(0, 1 - (life - 0.7) / 0.3)
            let rotation = piece.phase + piece.spin * tp
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: x, y: y)
                layer.rotate(by: .degrees(rotation))
                let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2,
                                  width: piece.size, height: piece.size * 0.6)
                let path = piece.isRect ? Path(roundedRect: rect, cornerRadius: 1.5) : Path(ellipseIn: rect)
                layer.fill(path, with: .color(piece.color))
            }
        }
    }

    // MARK: Particles

    private struct Piece: Identifiable {
        let id = UUID()
        let xFraction: Double      // 0…1 across the width
        let startYFraction: Double // slightly above the top edge
        let vx: Double             // horizontal drift, px/s
        let vy0: Double            // initial downward velocity, px/s
        let color: Color
        let size: Double
        let spin: Double           // deg/s
        let phase: Double          // starting rotation
        let wobble: Double         // lateral sway frequency
        let delay: Double
        let isRect: Bool
    }

    private static func makePieces(count: Int, palette: [Color]) -> [Piece] {
        (0..<count).map { _ in
            Piece(
                xFraction: .random(in: 0...1),
                startYFraction: .random(in: -0.08 ... 0.02),
                vx: .random(in: -70...70),
                vy0: .random(in: 30...120),
                color: palette.randomElement() ?? .accentColor,
                size: .random(in: 8...15),
                spin: .random(in: -340...340),
                phase: .random(in: 0...360),
                wobble: .random(in: 2...5),
                delay: .random(in: 0...0.2),
                isRect: .random()
            )
        }
    }

    // MARK: Palette derivation

    /// Five confetti shades derived from a base color: the color itself, a pastel-light and a
    /// deeper variant, a warm hue-shifted sibling, and a near-white sparkle. Keeps every burst
    /// unmistakably "that member's color" while staying lively.
    static func palette(from color: Color) -> [Color] {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a) else {
            return [color, color.opacity(0.7), .white]
        }
        func wrap(_ x: Double) -> Double {
            let m = x.truncatingRemainder(dividingBy: 1)
            return m < 0 ? m + 1 : m
        }
        func shade(hueDelta: Double, sat: Double, bri: Double) -> Color {
            Color(
                hue: wrap(Double(h) + hueDelta),
                saturation: min(max(Double(s) * sat, 0), 1),
                brightness: min(max(Double(b) * bri, 0), 1)
            )
        }
        return [
            color,
            shade(hueDelta: 0, sat: 0.55, bri: 1.2),    // pastel light
            shade(hueDelta: 0.06, sat: 1.0, bri: 0.95), // warm sibling
            shade(hueDelta: -0.06, sat: 1.05, bri: 0.85), // deeper sibling
            Color(hue: wrap(Double(h)), saturation: min(Double(s) * 0.2, 1), brightness: 1.0), // sparkle
        ]
    }
}

#if DEBUG
private struct ConfettiBurstDemo: View {
    @State private var trigger = 0
    @State private var colors: [Color] = [.terracotta, .marigold, .sky, .bacanGreen]
    @State private var current: Color = .marigold
    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            Button("¡Bacán! Level up") {
                current = colors.randomElement() ?? .marigold
                trigger += 1
            }
            .buttonStyle(.borderedProminent)
        }
        .overlay { ConfettiBurst(color: current, trigger: trigger).ignoresSafeArea() }
    }
}

#Preview("Confetti") { ConfettiBurstDemo() }
#endif
