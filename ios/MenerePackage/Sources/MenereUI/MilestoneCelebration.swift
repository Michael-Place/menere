import SwiftUI
import UIKit

// MARK: - MilestoneCelebration (D2 — the marquee moment)
//
// The BIGGEST, warmest moment in the app: when a family logs a KID MILESTONE ("Oliver said his
// first word!") we fire a treasured, keepsake celebration — a full-screen confetti downpour (a
// richer/longer sibling of the everyday care burst), a heartfelt banner in the kid's color, their
// avatar haloed by a star, and a gentle scale-in of the moment. ~2s, dismissable (tap the scrim or
// the card), plus a `.notification(.success)` haptic. This is the emotional PEAK — earned + special,
// never the everyday care burst.
//
// Reduce-Motion: the confetti physics + spring are skipped; a warm banner fades in (still with the
// success haptic) so the moment still lands. Self-contained: composes the shared ``ConfettiBurst``
// (public MenereUI API) — no edits to CelebrationKit / WaterCelebration / Haptics.
//
// Present it as a full-screen `.overlay` driven by an optional payload; it owns its own auto-dismiss
// timer and calls `onDismiss` when it's done (auto or tapped). Analytics (`milestone_celebrated`) is
// the caller's job — this view is pure UI.

/// A full-screen, keepsake celebration for a logged kid milestone. Drop it in a top-level `.overlay`
/// when a memory with a milestone is saved; drive it with the kid's first name, milestone text, and
/// color/avatar. Auto-dismisses after ~2s (or on tap), then calls `onDismiss`.
public struct MilestoneCelebration: View {
    private let kidName: String
    private let milestone: String
    private let tint: Color
    private let avatarSystemName: String
    private let milestoneSymbol: String
    private let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Two staggered confetti waves for a sustained downpour (richer than the single care burst).
    @State private var burstA = 0
    @State private var burstB = 0
    /// Drives the card's scale-in + the scrim fade.
    @State private var appeared = false
    /// A subtle continuous shimmer/pulse on the star badge while it's up.
    @State private var starPulse = false
    /// Guards against a double dismiss (auto timer racing a tap).
    @State private var closing = false

    private let visibleDuration: TimeInterval = 2.0

    public init(
        kidName: String,
        milestone: String,
        tint: Color,
        avatarSystemName: String = "person.circle.fill",
        milestoneSymbol: String = "star.fill",
        onDismiss: @escaping () -> Void
    ) {
        self.kidName = kidName
        self.milestone = milestone
        self.tint = tint
        self.avatarSystemName = avatarSystemName
        self.milestoneSymbol = milestoneSymbol
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            // A soft, warm scrim that lifts the keepsake off the timeline. Tap anywhere to keep it.
            Rectangle()
                .fill(.black.opacity(appeared ? 0.42 : 0))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            keepsakeCard
                .scaleEffect(cardScale)
                .opacity(appeared ? 1 : 0)
                .padding(.horizontal, 32)

            // The downpour — two full-screen waves of the kid's color. Skipped under Reduce Motion.
            if !reduceMotion {
                ConfettiBurst(color: tint, trigger: burstA)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                ConfettiBurst(color: .marigold, trigger: burstB)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLine)
        .accessibilityAddTraits(.isModal)
        .onAppear(perform: start)
    }

    private var cardScale: Double {
        guard appeared else { return reduceMotion ? 1 : 0.7 }
        return 1
    }

    // MARK: The keepsake card

    private var keepsakeCard: some View {
        VStack(spacing: 18) {
            avatarBadge

            VStack(spacing: 10) {
                Text(headline)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                // The milestone itself, worn as a proud pill in the kid's color.
                Label {
                    Text(milestoneTitle)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                } icon: {
                    Image(systemName: milestoneSymbol)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(
                    Capsule(style: .continuous)
                        .fill(tint)
                        .shadow(color: tint.opacity(0.4), radius: 8, y: 3)
                )

                Text("One for the scrapbook 🌟")
                    .font(.system(.caption, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.vertical, 30)
        .padding(.horizontal, 26)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.familySurface)
                .shadow(color: .black.opacity(0.22), radius: 26, y: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 1.5)
        )
    }

    /// The kid's avatar, haloed in their color with a star badge — the "this is about them" anchor.
    private var avatarBadge: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: 92, height: 92)
                .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 2))
                .overlay(
                    Image(systemName: avatarSystemName)
                        .font(.system(size: 46))
                        .foregroundStyle(tint)
                )

            // A gold star wink — the milestone stamp.
            Image(systemName: "star.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.marigold)
                .background(Circle().fill(Color.familySurface).frame(width: 30, height: 30))
                .scaleEffect(starPulse ? 1.12 : 0.9)
                .rotationEffect(.degrees(starPulse ? 8 : -8))
                .offset(x: 8, y: -6)
                .shadow(color: Color.marigold.opacity(0.5), radius: 5)
        }
    }

    // MARK: Copy (warm + witty, first names)

    private var name: String { kidName.isEmpty ? "Someone" : kidName }

    private var headline: String {
        let m = milestone.lowercased()
        if m.contains("word") || m.contains("said") { return "\(name) said their first word! 🎉" }
        if m.contains("step") || m.contains("walk") { return "\(name) took their first steps! 🎉" }
        if m.contains("tooth") { return "\(name) got a new tooth! 🎉" }
        if m.contains("crawl") { return "\(name) is crawling! 🎉" }
        if m.contains("roll") { return "\(name) rolled over! 🎉" }
        if m.contains("birthday") { return "Happy birthday, \(name)! 🎉" }
        if m.contains("swim") { return "\(name) took the plunge! 🎉" }
        if m.contains("school") { return "\(name)'s first day of school! 🎉" }
        return "\(name) reached a milestone! 🎉"
    }

    /// The milestone as a proud title-cased pill line (keeps free text intact).
    private var milestoneTitle: String {
        let trimmed = milestone.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "A brand-new milestone" : trimmed
    }

    private var accessibilityLine: String {
        "\(name) reached a milestone: \(milestoneTitle)"
    }

    // MARK: Lifecycle

    private func start() {
        // The emotional beat: a success buzz the instant the keepsake lands (device-only).
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        if reduceMotion {
            // Reduce Motion — a gentle fade, no spring, no confetti physics.
            withAnimation(.easeOut(duration: 0.3)) { appeared = true }
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) { appeared = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { starPulse = true }
            burstA += 1
            // A second, offset wave for a longer, fuller downpour than the everyday care burst.
            Task {
                try? await Task.sleep(for: .milliseconds(650))
                burstB += 1
            }
        }

        // Auto-dismiss after the moment has been savored.
        Task {
            try? await Task.sleep(for: .seconds(visibleDuration))
            close()
        }
    }

    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.easeIn(duration: 0.28)) { appeared = false }
        Task {
            try? await Task.sleep(for: .milliseconds(280))
            onDismiss()
        }
    }
}

// MARK: - Preview

#if DEBUG
private struct MilestoneCelebrationDemo: View {
    @State private var show = true
    @State private var nonce = 0

    var body: some View {
        ZStack {
            // A stand-in scrapbook timeline behind the celebration.
            Color.familyCanvas.ignoresSafeArea()
            VStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.familySurface)
                        .frame(height: 90)
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
                }
                Button("Log a milestone") { nonce += 1; show = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.bacanGreen)
            }
            .padding(24)
        }
        .overlay {
            if show {
                MilestoneCelebration(
                    kidName: "Oliver",
                    milestone: "First word",
                    tint: Color(red: 0.89, green: 0.63, blue: 0.18), // marigold — Oliver's color
                    avatarSystemName: "sun.max.circle.fill",
                    milestoneSymbol: "text.bubble.fill",
                    onDismiss: { show = false }
                )
                .id(nonce)
            }
        }
    }
}

#Preview("Milestone celebration") { MilestoneCelebrationDemo() }

#Preview("Milestone — generic") {
    ZStack {
        Color.familyCanvas.ignoresSafeArea()
        MilestoneCelebration(
            kidName: "Famfis",
            milestone: "First steps",
            tint: Color(red: 0.31, green: 0.58, blue: 0.78), // sky
            avatarSystemName: "figure.wave",
            milestoneSymbol: "figure.walk",
            onDismiss: {}
        )
    }
}
#endif
