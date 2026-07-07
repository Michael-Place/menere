import SwiftUI

// MARK: - ListDoneCelebration (D2 — "list done!")
//
// The whole-list payoff for check-off lists (grocery / packing / gift / wishlist / standard): when the
// check that completes the LAST item lands, a full-width `ConfettiBurst` rains and a warm little banner
// springs in — flavored by the kind of list. Tone matches the rest of the Delight Layer: **calm by
// default, joyful on accomplishment** — it fires once, on the completing check only (drive it with a
// monotonic `trigger` the caller advances exactly when the list flips to all-done), holds ~1.9s, then
// fades. Non-blocking (never intercepts touches), interruptible, and Reduce-Motion aware (confetti +
// spring skipped; the banner still fades in so the accomplishment still reads). A `.success` haptic
// fires on device.
//
// Usage — attach to the list view and bump `trigger` from the reducer when it detects completion:
//   SomeList().listDoneCelebration(trigger: store.listDoneTrigger, flavor: store.doneFlavor)

/// The flavor of a completed list — picks the banner emoji, headline, warm subline, and confetti tint.
/// Mirrors `FamilyDomain.ListType` without importing it (MenereUI stays free of the domain layer); map
/// your `ListType` → `ListDoneFlavor` at the call site.
public enum ListDoneFlavor: String, Sendable, CaseIterable, Equatable {
    case grocery
    case packing
    case gift
    case project
    case wishlist
    case standard

    /// The big emoji at the top of the banner.
    var emoji: String {
        switch self {
        case .grocery: "🛒"
        case .packing: "✈️"
        case .gift: "🎁"
        case .project: "🔨"
        case .wishlist: "✨"
        case .standard: "🎉"
        }
    }

    /// The headline line — first-name-warm, upbeat.
    var headline: String {
        switch self {
        case .grocery: "Groceries done!"
        case .packing: "All packed!"
        case .gift: "All sorted!"
        case .project: "Project complete!"
        case .wishlist: "All checked off!"
        case .standard: "All checked off!"
        }
    }

    /// A rotating warm + witty subline (picked by the trigger, so back-to-back completions vary).
    var sublines: [String] {
        switch self {
        case .grocery: ["Nothing left on the list.", "Cart's full — go you.", "Fridge, here it comes.", "Every aisle conquered."]
        case .packing: ["Bags are ready to roll.", "Nothing left behind.", "Wheels up soon ✈️", "Fully packed, zero panic."]
        case .gift: ["Everyone's covered.", "Shopping: handled.", "Surprises locked in 🎁", "Not a name left."]
        case .project: ["One for the done pile.", "Nailed it, start to finish.", "That's a wrap 🔨", "Off the honey-do list."]
        case .wishlist: ["Every wish, checked.", "The whole list — done.", "Nice work ✨", "All the way through."]
        case .standard: ["The whole list — done.", "Every box, checked.", "Clean sweep 🎉", "Nothing left to do."]
        }
    }

    /// The confetti + accent color.
    var tint: Color {
        switch self {
        case .grocery: .bacanGreen
        case .packing: .sky
        case .gift: .terracotta
        case .project: .marigold
        case .wishlist: .marigold
        case .standard: .bacanGreen
        }
    }
}

private struct ListDoneCelebrationModifier: ViewModifier {
    let trigger: Int
    let flavor: ListDoneFlavor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showBanner = false
    @State private var subline = ""
    @State private var dismissNonce = 0

    func body(content: Content) -> some View {
        content
            // Full-width confetti behind everything (self-skips under Reduce Motion, idle-cheap at rest).
            .overlay {
                ConfettiBurst(color: flavor.tint, trigger: trigger)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            // The warm banner, floating near the top so it doesn't cover the row just checked.
            .overlay(alignment: .top) {
                if showBanner {
                    banner
                        .padding(.top, 8)
                        .transition(bannerTransition)
                        .allowsHitTesting(false)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(flavor.headline) \(subline)")
                }
            }
            // Device-only success buzz on the completing check.
            .sensoryFeedback(.success, trigger: trigger)
            .onChange(of: trigger) { _, newValue in
                guard newValue > 0 else { return }
                subline = flavor.sublines[(newValue - 1) % flavor.sublines.count]
                dismissNonce += 1
                let nonce = dismissNonce
                if reduceMotion {
                    withAnimation(.easeOut(duration: 0.25)) { showBanner = true }
                } else {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { showBanner = true }
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(1900))
                    guard nonce == dismissNonce else { return } // a newer completion owns the banner now
                    withAnimation(.easeOut(duration: 0.35)) { showBanner = false }
                }
            }
    }

    private var bannerTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .scale(scale: 0.7, anchor: .top).combined(with: .opacity)
    }

    private var banner: some View {
        VStack(spacing: 6) {
            Text(flavor.emoji)
                .font(.system(size: 40))
            Text(flavor.headline)
                .font(.system(.title3, design: .rounded).weight(.heavy))
                .foregroundStyle(Color.ink)
            Text(subline)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.familySurface)
                .shadow(color: flavor.tint.opacity(0.28), radius: 18, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(flavor.tint.opacity(0.35), lineWidth: 1.5)
        )
        .padding(.horizontal, 40)
    }
}

public extension View {
    /// Play the whole-list "list done!" celebration — a flavored `ConfettiBurst` + a warm banner + a
    /// `.success` haptic — on each advance of `trigger`. Drive `trigger` from the reducer *only* on the
    /// check that flips the list to all-complete (never on a re-render of an already-complete list).
    /// `flavor` picks the copy + confetti color. See ``ListDoneFlavor``.
    func listDoneCelebration(trigger: Int, flavor: ListDoneFlavor) -> some View {
        modifier(ListDoneCelebrationModifier(trigger: trigger, flavor: flavor))
    }
}

#if DEBUG
private struct ListDoneCelebrationDemo: View {
    @State private var trigger = 0
    @State private var flavor: ListDoneFlavor = .grocery

    private let flavors = ListDoneFlavor.allCases

    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()
            VStack(spacing: 22) {
                Text("Tap a flavor to fire the celebration")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Color.ink)
                ForEach(flavors, id: \.self) { f in
                    Button {
                        flavor = f
                        trigger += 1
                    } label: {
                        HStack {
                            Text(f.emoji)
                            Text(f.headline)
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(Capsule().fill(f.tint.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
        }
        .listDoneCelebration(trigger: trigger, flavor: flavor)
    }
}

#Preview("List done — all flavors") { ListDoneCelebrationDemo() }
#endif
