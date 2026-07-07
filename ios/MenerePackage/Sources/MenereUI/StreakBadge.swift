import SwiftUI

// MARK: - StreakBadge (D3 — positive-only streaks)
//
// The gentle face of a care streak. Two pieces, both **celebration-only** — nothing here ever scolds,
// guilts, or shows a "lost streak":
//
//   • `StreakBadge` — a subtle "🔥 {n}" chip on a care row, shown ONLY once the streak is worth a
//     quiet nod (≥ `CareStreak.badgeThreshold`, i.e. 3). Below that it renders *nothing* — no number,
//     no pressure, no expectation to keep anything going.
//   • `.streakMilestone(streak:trigger:)` — a small, joyful burst + "🔥 {n}-day streak! Keep it going
//     🌿" when a completion lands the streak exactly on a milestone (7/14/30/60/100). Brief, warm, and
//     interruptible; reuses the shared `ConfettiBurst`. A missed streak resets silently elsewhere —
//     this modifier only ever fires on a *win*, so nothing negative can surface through it.
//
// Tone: encouraging + calm — a warm-hearth flame, not a slot machine. Reduce-Motion aware (the
// confetti self-skips; the toast stays as a soft, static line).

/// A subtle "🔥 {n}" streak chip for a care row. Renders nothing when the streak is below the
/// ``StreakBadge/threshold`` (3, mirroring `FamilyDomain.CareStreak.badgeThreshold`) — so it appears
/// only as an encouraging little reward, never as a running counter that could read as pressure.
/// Warm marigold, small, unobtrusive. Kept free of any domain import so it stays in `MenereUI`.
public struct StreakBadge: View {
    /// The streak length at/above which the badge appears. Mirrors `CareStreak.badgeThreshold`
    /// (they must agree); duplicated as a literal only because `MenereUI` doesn't import `FamilyDomain`.
    public static let threshold = 3

    private let streak: Int?
    private let compact: Bool

    /// - Parameters:
    ///   - streak: the care task's `streakCount` (nil/0/< 3 ⇒ nothing shown).
    ///   - compact: drop the flame's trailing padding for tight rows (default `false`).
    public init(streak: Int?, compact: Bool = false) {
        self.streak = streak
        self.compact = compact
    }

    public var body: some View {
        if let n = streak, n >= Self.threshold {
            HStack(spacing: 3) {
                Text("🔥").font(.system(size: compact ? 10 : 11))
                Text("\(n)")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.terracotta)
            }
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous).fill(Color.marigold.opacity(0.18))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(n) day streak")
        }
    }
}

// MARK: - Milestone celebration

private struct StreakMilestoneCelebration: ViewModifier {
    let streak: Int
    let trigger: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var toast: String?
    @State private var nonce = 0

    func body(content: Content) -> some View {
        content
            // A warm marigold confetti rain, sized a touch larger than the row so it isn't clipped.
            .overlay {
                ConfettiBurst(color: .marigold, trigger: trigger)
                    .frame(width: 220, height: 160)
                    .allowsHitTesting(false)
            }
            // The cheerful, brief milestone line — floats above, springs in, then fades.
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous).fill(Color.marigold)
                                .shadow(color: Color.marigold.opacity(0.4), radius: 7, y: 2)
                        )
                        .fixedSize()
                        .offset(y: -30)
                        .allowsHitTesting(false)
                        .accessibilityLabel(toast)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0 else { return }
                nonce += 1
                let mine = nonce
                withAnimation(.spring(response: 0.36, dampingFraction: 0.62)) {
                    toast = "🔥 \(streak)-day streak! Keep it going 🌿"
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(1900))
                    guard mine == nonce else { return } // a newer milestone owns the toast now
                    withAnimation(.easeOut(duration: 0.3)) { toast = nil }
                }
            }
    }
}

public extension View {
    /// Fire a small, POSITIVE streak-milestone celebration over this row — a marigold ``ConfettiBurst``
    /// + "🔥 {streak}-day streak! Keep it going 🌿" — each time `trigger` advances. Drive `trigger` only
    /// when a completion lands the streak exactly on a milestone (``CareStreak/isMilestone(_:)``); on any
    /// other completion, don't advance it and nothing happens beyond the normal care celebration. There
    /// is no negative counterpart — a broken streak resets silently, so this never surfaces a loss.
    func streakMilestone(streak: Int, trigger: Int) -> some View {
        modifier(StreakMilestoneCelebration(streak: streak, trigger: trigger))
    }
}

// MARK: - Preview

#if DEBUG
private struct StreakBadgeDemo: View {
    @State private var milestoneTrigger = 0
    @State private var milestoneStreak = 7

    private let sampleStreaks = [1, 2, 3, 5, 7, 14, 30, 100]

    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Streak badge — shows only at ≥ 3")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)

                VStack(spacing: 10) {
                    ForEach(sampleStreaks, id: \.self) { n in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.bacanGreen.opacity(0.15))
                                Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen)
                            }
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("Water · Monstera").foregroundStyle(Color.ink)
                                    StreakBadge(streak: n)
                                }
                                Text("streakCount = \(n)")
                                    .font(.caption).foregroundStyle(Color.inkSoft)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.familySurface))
                    }
                }

                Button("Fire milestone celebration 🔥") {
                    milestoneStreak = [7, 14, 30, 100].randomElement() ?? 7
                    milestoneTrigger += 1
                }
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Capsule().fill(Color.marigold))
                .streakMilestone(streak: milestoneStreak, trigger: milestoneTrigger)
                .padding(.top, 8)
            }
            .padding(24)
        }
    }
}

#Preview("StreakBadge + milestone") { StreakBadgeDemo() }
#endif
