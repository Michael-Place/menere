import SwiftUI
import UIKit

// MARK: - CelebrationKit
//
// ONE reusable delight kit (D1) — generalized from the D0 watering celebration. A single modifier,
// `.careCelebration(trigger:style:name:)`, plays a FLAVORED burst + a rotating reward toast over any
// care-done button; a `style` picks the flavor. Pair it with `CelebrationGlyph(trigger:style:)` for
// the button icon (a flavor symbol that morphs to a check), `.careBounce(trigger:)` for the thing
// being cared-for to perk up, and `MenereHaptics.celebrate(style)` fired from the button action.
//
//   • `.water`     — droplets + ripple (the D0 `WaterBurst`) — "Slurp! 💧".
//   • `.fertilize` — a green leaf/sparkle pop — "Well fed 🌿".  (alias: `.leaf`)
//   • `.repot`     — an earthy soil pop — "Fresh digs 🪴".      (alias: `.earth`)
//   • `.pet`       — a 🐾 paw + sparkle burst — "{Name} says thanks! 🐾".
//   • `.house`     — a 🔧 wrench + spark burst — "Handled 🔧".
//   • `.generic`   — a soft ✨ sparkle/confetti fallback — "Done! ✨".
//
// Tone: **calm by default, joyful on accomplishment** — quick (~0.6–1s), non-blocking (never
// intercepts touches), interruptible (fast repeats restart cleanly), never spammy. Reduce-Motion =
// haptic + the quick glyph morph only (bursts + toast skipped). Everything is pure SwiftUI Canvas /
// keyframes — no dependencies, idle-cheap (paused `TimelineView`s).

/// The flavor of a care celebration — picks the burst particles, palette, reward-toast micro-copy,
/// button glyph, and haptic. Map your domain's care kind/task to a style (see `CelebrationKit`).
public enum CelebrationStyle: String, Sendable, CaseIterable, Equatable {
    /// Watering — droplets + ripple. The D0 flavor.
    case water
    /// Feeding / leafy plant care — a green leaf + sparkle pop.
    case fertilize
    /// Re-potting — an earthy soil pop.
    case repot
    /// Pet care (meds, grooming, vet) — a paw-print + sparkle burst.
    case pet
    /// House / zone maintenance — a wrench + spark burst.
    case house
    /// A soft, kind-agnostic sparkle/confetti fallback.
    case generic

    /// Alias: `.fertilize` reads as "leaf" at some call sites.
    public static var leaf: CelebrationStyle { .fertilize }
    /// Alias: `.repot` reads as "earth" at some call sites.
    public static var earth: CelebrationStyle { .repot }
}

// MARK: - Per-style configuration

extension CelebrationStyle {
    /// The accent for the reward-toast capsule + the rest state of `CelebrationGlyph`. Public so call
    /// sites can tint their own pill/label to match the flavor.
    public var tint: Color {
        switch self {
        case .water: .sky
        case .fertilize: .bacanGreen
        case .repot: .terracotta
        case .pet: .sky
        case .house: .marigold
        case .generic: .bacanGreen
        }
    }

    /// The button glyph at rest (morphs to a check on completion). Mirrors the care system's own
    /// task symbols so the button reads as its verb before you tap it. Public for call-site glyphs.
    public var restSymbol: String {
        switch self {
        case .water: "drop.fill"
        case .fertilize: "leaf.fill"
        case .repot: "shippingbox.fill"
        case .pet: "pawprint.fill"
        case .house: "wrench.and.screwdriver.fill"
        case .generic: "checkmark.circle.fill"
        }
    }

    /// Emoji flung by the burst (unused for `.water`, which draws bespoke droplets).
    var burstEmoji: [String] {
        switch self {
        case .water: ["💧", "💦"]
        case .fertilize: ["🌿", "🍃", "✨", "🌱"]
        case .repot: ["🪴", "🌱", "🍂"]
        case .pet: ["🐾", "✨", "🦴", "🐾"]
        case .house: ["🔧", "✨", "🛠️", "🏡"]
        case .generic: ["✨", "🎉", "⭐️"]
        }
    }

    /// Small confetti-dot palette scattered alongside the emoji (adds color body to the pop).
    var particlePalette: [Color] {
        switch self {
        case .water: Color.waterPalette
        case .fertilize: [.bacanGreen, Color(uiColor: UIColor(hex: 0x8FCB6A)), Color(uiColor: UIColor(hex: 0xD9F0C2)), .marigold]
        case .repot: [.terracotta, Color(uiColor: UIColor(hex: 0x9C6B3F)), Color(uiColor: UIColor(hex: 0xE7C9A9)), .bacanGreen]
        case .pet: [.sky, .marigold, Color(uiColor: UIColor(hex: 0xEAF6FD)), Color(uiColor: UIColor(hex: 0xF4C77E))]
        case .house: [.marigold, .sky, Color(uiColor: UIColor(hex: 0xFBE7B0)), .bacanGreen]
        case .generic: [.bacanGreen, .marigold, .sky, .terracotta]
        }
    }

    /// The rotating reward lines — warm + witty, first-name voice. `{Name}` fills in the plant/pet
    /// name when provided (falls back to "It"). One line is picked per trigger, rotating in order.
    var quips: [String] {
        switch self {
        case .water:
            ["Slurp! 💧", "Ahh, refreshing 🌿", "{Name} says thanks!", "Hydrated ✨", "Glug glug 💦"]
        case .fertilize:
            ["Well fed 🌿", "Growth incoming ✨", "Yum, nutrients!", "{Name}'s thriving 🌱", "Snack time 🍃"]
        case .repot:
            ["Fresh digs 🪴", "Room to grow!", "New home, {Name}!", "Cozy roots 🌱", "Stretch out ✨"]
        case .pet:
            ["{Name} says thanks! 🐾", "Good pup 🦴", "Tail wags all around", "Who's a good {Name}?", "Belly rubs earned ✨"]
        case .house:
            ["Handled 🔧", "House happy 🏡", "Nailed it!", "One less thing ✨", "Ship-shape 🛠️"]
        case .generic:
            ["Done! ✨", "Nice one!", "Checked off 🎉", "Boom — handled", "One down ⭐️"]
        }
    }
}

// MARK: - CelebrationBurst (the flavored particle burst)

/// The burst overlay for a care celebration: for `.water` it embeds the bespoke ``WaterBurst``
/// (droplets + ripple); for every other style it flings the style's EMOJI plus small confetti dots
/// outward from the tap point under gravity — an instantly-legible flavor pop (🐾 / 🌿 / 🪴 / 🔧 / ✨).
///
/// Drive with a monotonic `trigger`. Mount as an overlay sized larger than the button so particles
/// aren't clipped. Non-blocking, interruptible (a `.task(id:)` owns one burst), and Reduce-Motion
/// aware (skipped entirely). ~0.85s, then idle (a paused `TimelineView`, so it costs nothing at rest).
public struct CelebrationBurst: View {
    private let style: CelebrationStyle
    private let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particles: [Particle] = []
    @State private var startDate: Date?

    private let duration: TimeInterval = 0.85
    private let gravity: Double = 850 // px/s²

    public init(style: CelebrationStyle, trigger: Int) {
        self.style = style
        self.trigger = trigger
    }

    public var body: some View {
        Group {
            if style == .water {
                // Reuse the D0 droplet + ripple physics for water.
                WaterBurst(trigger: trigger)
            } else {
                TimelineView(.animation(paused: startDate == nil)) { timeline in
                    Canvas { context, size in
                        guard let start = startDate else { return }
                        draw(at: timeline.date.timeIntervalSince(start), size: size, context: &context)
                    }
                }
                .task(id: trigger) {
                    guard trigger > 0, !reduceMotion else { return }
                    particles = Self.makeParticles(style: style)
                    startDate = .now
                    do {
                        try await Task.sleep(for: .seconds(duration + 0.05))
                    } catch {
                        return // cancelled by a newer trigger — that run owns the reset
                    }
                    startDate = nil
                    particles = []
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(at t: TimeInterval, size: CGSize, context: inout GraphicsContext) {
        guard t <= duration else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for p in particles {
            let tp = t - p.delay
            guard tp >= 0 else { continue }
            let x = center.x + p.vx * tp
            let y = center.y + p.vy0 * tp + 0.5 * gravity * tp * tp
            let life = min(1, tp / (duration - p.delay))
            // A brief pop-in, hold, then fade as it falls.
            let opacity: Double = life < 0.12 ? (life / 0.12)
                : (life < 0.72 ? 1.0 : max(0, 1 - (life - 0.72) / 0.28))
            guard opacity > 0.01 else { continue }
            let rotation = p.phase + p.spin * tp
            context.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: x, y: y)
                layer.rotate(by: .degrees(rotation))
                switch p.kind {
                case let .emoji(symbol):
                    let scale = 0.7 + 0.3 * min(1, life / 0.18) // a little scale-in
                    layer.scaleBy(x: scale, y: scale)
                    // Resolve against the live context (the supported path); cheap for a handful.
                    let resolved = layer.resolve(Text(symbol).font(.system(size: p.size)))
                    layer.draw(resolved, at: .zero)
                case let .dot(color):
                    let r = p.size / 2
                    layer.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: p.size, height: p.size)),
                               with: .color(color))
                }
            }
        }
    }

    // MARK: Particles

    private struct Particle: Identifiable {
        enum Kind {
            case emoji(String)
            case dot(Color)
        }
        let id = UUID()
        let kind: Kind
        let vx: Double
        let vy0: Double
        let size: Double
        let spin: Double   // deg/s
        let phase: Double  // starting rotation
        let delay: Double
    }

    private static func makeParticles(style: CelebrationStyle) -> [Particle] {
        var out: [Particle] = []
        // A handful of emoji glyphs — the recognizable flavor.
        for _ in 0..<6 {
            let angle = Double.random(in: (.pi * 0.12)...(.pi * 0.88)) // arc upward
            let speed = Double.random(in: 90...200)
            let symbol = style.burstEmoji.randomElement() ?? "✨"
            let fontSize = Double.random(in: 17...25)
            out.append(Particle(
                kind: .emoji(symbol),
                vx: cos(angle) * speed,
                vy0: -sin(angle) * speed,
                size: fontSize,
                spin: .random(in: -140...140),
                phase: .random(in: -12...12),
                delay: .random(in: 0...0.06)
            ))
        }
        // A scatter of small colored confetti dots for body.
        for _ in 0..<10 {
            let angle = Double.random(in: (.pi * 0.05)...(.pi * 0.95))
            let speed = Double.random(in: 70...190)
            out.append(Particle(
                kind: .dot(style.particlePalette.randomElement() ?? style.tint),
                vx: cos(angle) * speed,
                vy0: -sin(angle) * speed,
                size: .random(in: 5...9),
                spin: .random(in: -260...260),
                phase: .random(in: 0...360),
                delay: .random(in: 0...0.08)
            ))
        }
        return out
    }
}

// MARK: - careCelebration modifier (burst + reward toast)

private struct CareCelebration: ViewModifier {
    let trigger: Int
    let style: CelebrationStyle
    let name: String?
    /// D1.5 — when provided, the reward toast grows a tappable **Undo** chip during its window, so an
    /// accidental "watered" tap is reversible without hunting for a menu. `nil` ⇒ no undo affordance.
    let onUndo: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toastText: String?
    @State private var toastNonce = 0

    func body(content: Content) -> some View {
        content
            // The flavored burst, on a frame larger than the button so fast particles don't clip.
            .overlay {
                CelebrationBurst(style: style, trigger: trigger)
                    .frame(width: 180, height: 180)
                    .allowsHitTesting(false)
            }
            // The cheerful reward micro-copy, floating just above the button. Anchored trailing so a
            // wide line grows leftward and can't run off the right screen edge.
            .overlay(alignment: .topTrailing) {
                if let toastText {
                    HStack(spacing: 7) {
                        Text(toastText)
                            .accessibilityHidden(true)
                        if onUndo != nil {
                            // A hairline divider + a tappable Undo — the accidental-tap escape hatch.
                            Rectangle().fill(.white.opacity(0.4)).frame(width: 1, height: 12)
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) { self.toastText = nil }
                                toastNonce += 1   // invalidate the pending auto-dismiss
                                onUndo?()
                            } label: {
                                Text("Undo").underline()
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Undo")
                            .accessibilityIdentifier("celebration-undo")
                        }
                    }
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous).fill(style.tint)
                            .shadow(color: style.tint.opacity(0.35), radius: 6, y: 2)
                    )
                    .fixedSize()
                    .offset(y: -34)
                    // Hit-testable only when there's an Undo to tap; otherwise stays inert over the button.
                    .allowsHitTesting(onUndo != nil)
                    .id(toastNonce)
                    .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0, !reduceMotion else { return }
                let quips = style.quips
                let line = quips[(newValue - 1) % quips.count]
                let first = (name?.split(separator: " ").first)
                    .map(String.init)?
                    .trimmingCharacters(in: .punctuationCharacters)
                    .nilIfEmpty ?? "It"
                toastNonce += 1
                let nonce = toastNonce
                withAnimation(.spring(response: 0.34, dampingFraction: 0.6)) {
                    toastText = line
                        .replacingOccurrences(of: "{Name}", with: first)
                        .replacingOccurrences(of: "{PlantName}", with: first)
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard nonce == toastNonce else { return } // a newer tap owns the toast now
                    withAnimation(.easeOut(duration: 0.25)) { toastText = nil }
                }
            }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - careBounce modifier (the thing perks up)

/// A happy little spring BOUNCE for the cared-for thing's row/thumbnail — it scales up ~8% with a
/// slight sway and settles ("it perked up"). Keyed to the same `trigger` as the celebration; plays
/// only when the trigger advances. Skipped under Reduce Motion. Kind-agnostic (plant/pet/house).
private struct CareBounce: ViewModifier {
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

// MARK: - CelebrationGlyph (flavor symbol → checkmark morph)

/// A care button's icon: the style's flavor symbol at rest (droplet / leaf / box / paw / wrench) that
/// MORPHS to a checkmark for a beat on completion, then settles — the "done!" wink. A symbol-replace
/// content transition, so it stays gentle and IS the Reduce-Motion payoff (this glyph swap survives).
public struct CelebrationGlyph: View {
    private let trigger: Int
    private let style: CelebrationStyle
    private let size: CGFloat

    @State private var showCheck = false

    public init(trigger: Int, style: CelebrationStyle, size: CGFloat = 20) {
        self.trigger = trigger
        self.style = style
        self.size = size
    }

    public var body: some View {
        Image(systemName: showCheck ? "checkmark.circle.fill" : style.restSymbol)
            .font(.system(size: size))
            .foregroundStyle(showCheck ? Color.bacanGreen : style.tint)
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
    /// Play the full care celebration — a flavored burst + a rotating reward toast — over this button
    /// on each advance of `trigger`. `style` picks the flavor; pass `name` so the toast can say
    /// "{first name} says thanks!". Pair with `MenereHaptics.celebrate(style)` in the button action and
    /// `CelebrationGlyph(trigger:style:)` for the icon. See ``CelebrationStyle`` / ``CelebrationBurst``.
    func careCelebration(
        trigger: Int, style: CelebrationStyle, name: String? = nil, onUndo: (() -> Void)? = nil
    ) -> some View {
        modifier(CareCelebration(trigger: trigger, style: style, name: name, onUndo: onUndo))
    }

    /// A happy spring bounce for the cared-for thing's row/thumbnail. Drive with the same `trigger`
    /// as `careCelebration`. Skipped under Reduce Motion. See ``CareBounce``.
    func careBounce(trigger: Int) -> some View {
        modifier(CareBounce(trigger: trigger))
    }
}

// MARK: - D0 water back-compat

public extension View {
    /// D0 compatibility shim — the original water celebration, now a `.water`-flavored
    /// `careCelebration`. Prefer `.careCelebration(trigger:style:.water, name:)` directly.
    func waterCelebration(trigger: Int, plantName: String? = nil) -> some View {
        careCelebration(trigger: trigger, style: .water, name: plantName)
    }

    /// D0 compatibility shim — the plant perk-up bounce, now the kind-agnostic `.careBounce`.
    func plantBounce(trigger: Int) -> some View {
        careBounce(trigger: trigger)
    }
}

/// D0 compatibility shim — the water button glyph, now a `.water`-flavored ``CelebrationGlyph``.
/// The `restSymbol` / `tint` params are honored for callers that customized them.
public struct WaterGlyph: View {
    private let trigger: Int
    private let size: CGFloat

    public init(trigger: Int, size: CGFloat = 20, restSymbol: String = "drop.fill", tint: Color = .bacanGreen) {
        self.trigger = trigger
        self.size = size
        _ = restSymbol; _ = tint // the `.water` style owns the droplet symbol + sky tint now
    }

    public var body: some View {
        CelebrationGlyph(trigger: trigger, style: .water, size: size)
    }
}

// MARK: - Preview

#if DEBUG
private struct CelebrationKitDemo: View {
    @State private var triggers: [CelebrationStyle: Int] = [:]

    private let rows: [(CelebrationStyle, String, String)] = [
        (.water, "Monstera", "Water"),
        (.fertilize, "Fiddle Leaf", "Fertilize"),
        (.repot, "Pothos", "Re-pot"),
        (.pet, "Fajita", "Meds"),
        (.house, "HVAC filter", "Replace"),
        (.generic, "Something", "Done"),
    ]

    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            VStack(spacing: 14) {
                ForEach(rows, id: \.0) { style, name, verb in
                    let trigger = triggers[style] ?? 0
                    HStack(spacing: 16) {
                        ZStack {
                            Circle().fill(style.tint.opacity(0.15))
                            Image(systemName: style.restSymbol).foregroundStyle(style.tint)
                        }
                        .frame(width: 44, height: 44)
                        .careBounce(trigger: trigger)

                        Text(name).font(.system(.body, design: .rounded))
                        Spacer()

                        Button {
                            triggers[style, default: 0] += 1
                            MenereHaptics.celebrate(style)
                        } label: {
                            HStack(spacing: 5) {
                                CelebrationGlyph(trigger: trigger, style: style, size: 18)
                                Text(verb).font(.system(.footnote, design: .rounded).weight(.semibold))
                            }
                            .foregroundStyle(style.tint)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(style.tint.opacity(0.14)))
                        }
                        .buttonStyle(.pressable)
                        .careCelebration(trigger: trigger, style: style, name: name)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Capsule().fill(Color.familySurface))
                }
            }
            .padding(24)
        }
    }
}

#Preview("CelebrationKit — all styles") { CelebrationKitDemo() }
#endif
