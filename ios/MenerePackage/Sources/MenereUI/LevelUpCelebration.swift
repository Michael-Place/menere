import SwiftUI

// MARK: - D2 (chores) — the big-completion delight for XP & level-up
//
// Two self-contained MenereUI delight components for the Chores → XP → level-up loop, kept together
// because they share the "you earned this" moment:
//
//   • `XPFly`             — a "+{n} XP" number that pops in, floats up, and fades. Drives off a
//                           monotonic `trigger`; drop it over the member's XP/level bar so a chore
//                           completion reads as points landing ON that bar.
//   • `LevelUpCelebration` — the BIG one: a crown + "Level {N}! 🎉" card in the member's color, with a
//                           full-screen member-colored `ConfettiBurst` behind it (the crown+confetti
//                           the tvOS leaderboard already wears, brought to the phone). ~1.6s, tap to
//                           dismiss, then auto-clears.
//
// Tone: **calm by default, joyful on accomplishment** — earned + warm, never a slot-machine. Both are
// `accessibilityReduceMotion`-aware: `XPFly` shortens its travel; `LevelUpCelebration` drops the
// confetti physics + backdrop dim for a quiet level-up banner (the haptic + the crown still land).
// Pure SwiftUI + the existing `ConfettiBurst`; no dependencies.

// MARK: - XPFly

/// A "+{amount} XP" reward chip that pops in, floats upward, and fades — the points-landed hit for a
/// chore completion. Mount it as a `.overlay` on (or near) the member's XP/level bar and drive it with
/// a monotonic `trigger` that advances only when THIS member is credited. Non-blocking, interruptible,
/// idle-cheap. Under Reduce Motion it makes a short quiet rise instead of the full fly.
public struct XPFly: View {
    private let trigger: Int
    private let amount: Int
    private let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flying = false     // drives the up-and-out travel + fade
    @State private var shown = false      // gates the pop-in / presence
    @State private var displayAmount = 0  // frozen at fire time so a late store change can't garble it

    public init(trigger: Int, amount: Int, color: Color) {
        self.trigger = trigger
        self.amount = amount
        self.color = color
    }

    public var body: some View {
        Text("+\(displayAmount) XP")
            .font(.system(.caption2, design: .rounded).weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous).fill(color.opacity(0.18))
                    .shadow(color: color.opacity(0.25), radius: 3, y: 1)
            )
            .offset(y: flying ? (reduceMotion ? -16 : -48) : -4)
            .opacity(shown ? (flying ? 0 : 1) : 0)
            .scaleEffect(shown ? 1 : 0.7, anchor: .center)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0, amount > 0 else { return }
                displayAmount = amount
                flying = false                      // snap to the start pose (no animation)
                withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { shown = true }
                withAnimation(.easeOut(duration: reduceMotion ? 0.35 : 0.9)) { flying = true }
                Task {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 550 : 950))
                    shown = false
                    flying = false
                }
            }
    }
}

// MARK: - LevelUpCelebration

/// The BIG level-up moment: a crown + "Level {N}! 🎉" card tinted to the member's color, with a
/// full-screen member-colored ``ConfettiBurst`` raining behind it. Drive it with a monotonic
/// `trigger` (bump it the instant `memberStats.level` rises); it captures `level`/`memberName` at fire
/// time, celebrates ~1.6s, then auto-dismisses (also tap-to-dismiss). `onDismiss` fires once when it
/// clears so the owner can reset its presented state.
///
/// Reduce Motion: no confetti, no backdrop dim, no pop physics — just a quiet level-up banner sliding
/// down from the top (plus the success haptic). Mount as a top-level `.overlay`.
public struct LevelUpCelebration: View {
    private let trigger: Int
    private let level: Int
    private let color: Color
    private let memberName: String?
    private let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var pop = false
    @State private var confettiTrigger = 0
    @State private var displayLevel = 0
    @State private var displayName: String?
    @State private var dismissTask: Task<Void, Never>?

    public init(
        trigger: Int, level: Int, color: Color, memberName: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.trigger = trigger
        self.level = level
        self.color = color
        self.memberName = memberName
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            if visible {
                if reduceMotion {
                    quietBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { dismiss() }
                    card
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .onTapGesture { dismiss() }
                    ConfettiBurst(color: color, trigger: confettiTrigger)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: trigger) { _, newValue in
            guard newValue > 0 else { return }
            present()
        }
        .onDisappear { dismissTask?.cancel() }
    }

    // The full crown card (default / motion-on path).
    private var card: some View {
        VStack(spacing: 10) {
            Image(systemName: "crown.fill")
                .font(.system(size: 52))
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.4), radius: 10, y: 3)
                .scaleEffect(pop ? 1 : 0.4)
                .rotationEffect(.degrees(pop ? 0 : -12))
            Text("Level \(displayLevel)! 🎉")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.ink)
            Text(subtitle)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.familySurface)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(color.opacity(0.4), lineWidth: 2)
        )
        .scaleEffect(pop ? 1 : 0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // The Reduce-Motion path: a compact, still banner near the top — no confetti, no dim.
    private var quietBanner: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "crown.fill")
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Level \(displayLevel)")
                        .font(.system(.headline, design: .rounded).weight(.heavy))
                        .foregroundStyle(Color.ink)
                    if let name = displayName, !name.isEmpty {
                        Text("\(firstName(name)) leveled up")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Color.inkSoft)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous).fill(Color.familySurface)
                    .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1.5))
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .onTapGesture { dismiss() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        if let name = displayName, !name.isEmpty { return "\(firstName(name)) leveled up!" }
        return "Leveled up!"
    }

    private var accessibilityText: String {
        if let name = displayName, !name.isEmpty { return "\(firstName(name)) reached level \(displayLevel)" }
        return "Level \(displayLevel) reached"
    }

    private func present() {
        displayLevel = level
        displayName = memberName
        dismissTask?.cancel()
        MenereHaptics.celebrate(.generic)   // device-only; the "you earned it" buzz
        withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) { visible = true }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(0.04)) { pop = true }
        if !reduceMotion { confettiTrigger += 1 }
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 1500 : 1650))
            guard !Task.isCancelled else { return }
            await MainActor.run { dismiss() }
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.28)) {
            visible = false
            pop = false
        }
        onDismiss()
    }

    private func firstName(_ full: String) -> String {
        full.split(separator: " ").first.map(String.init) ?? full
    }
}

// MARK: - Previews

#if DEBUG
private struct LevelUpDemo: View {
    @State private var trigger = 0
    @State private var xpTrigger = 0
    @State private var level = 4
    @State private var color: Color = .marigold
    private let palette: [Color] = [.terracotta, .marigold, .sky, .bacanGreen]

    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            VStack(spacing: 28) {
                // A stand-in leaderboard bar with the +XP fly landing on it.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Valentina").font(.system(.body, design: .rounded)).foregroundStyle(Color.ink)
                        Spacer()
                        Text("Lv \(level)").font(.caption).foregroundStyle(Color.inkSoft)
                    }
                    ProgressView(value: 0.6).tint(color)
                        .overlay(alignment: .trailing) {
                            XPFly(trigger: xpTrigger, amount: 15, color: color)
                        }
                }
                .padding().background(Capsule(style: .continuous).fill(Color.familySurface))

                Button("Complete a chore (+XP)") { xpTrigger += 1 }
                    .buttonStyle(.borderedProminent)

                Button("Level up! 🎉") {
                    color = palette.randomElement() ?? .marigold
                    level += 1
                    trigger += 1
                }
                .buttonStyle(.borderedProminent)
                .tint(.bacanGreen)
            }
            .padding(28)
        }
        .overlay {
            LevelUpCelebration(
                trigger: trigger, level: level, color: color, memberName: "Valentina Place",
                onDismiss: {}
            )
        }
    }
}

#Preview("LevelUp + XPFly") { LevelUpDemo() }

#Preview("LevelUp — card only") {
    ZStack {
        Color.familyCanvas.ignoresSafeArea()
    }
    .overlay {
        LevelUpCelebrationStaticPreview()
    }
}

/// A non-interactive render of the crown card for a still preview/screenshot.
private struct LevelUpCelebrationStaticPreview: View {
    @State private var t = 0
    var body: some View {
        LevelUpCelebration(trigger: t, level: 5, color: .marigold, memberName: "Oliver", onDismiss: {})
            .onAppear { t = 1 }
    }
}
#endif
