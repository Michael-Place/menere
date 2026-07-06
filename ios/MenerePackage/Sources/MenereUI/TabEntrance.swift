import SwiftUI

/// Motion & Delight — the shared **tab load-in system**. Every primary tab plays a signature
/// staggered entrance both on cold launch and again each time it's (re)selected, so navigating the
/// app feels alive ("surprise & delight as I navigate between tabs").
///
/// ## How it works
/// `MainTabView` injects a monotonic `\.tabEntranceTrigger` token into each tab's root, bumping it
/// whenever that tab becomes selected (and once on first render, for the default tab). Any view
/// tagged with `.tabEntrance(_:index:)` watches that token and **replays** its reveal whenever it
/// advances — hidden → visible with an index-based stagger and a springy settle.
///
/// ## Signatures (variety = the delight)
/// - `.cascade` — Today's sections fade + slide-up + subtle scale, top→bottom.
/// - `.pop` — Today's family grid pops in with a `.stickerSlap`-style overshoot.
/// - `.tumble` — Memories' scrapbook pages land with a slight rotation settle (±4° → 0).
/// - `.slideLeading` — Lists' rows write themselves in from the leading edge.
/// - `.bloom` — Home's care cards grow in (scale 0.9→1, gentle overshoot — a plant-growth feel).
/// - `.rise` — Kitchen's recipe cards plate up (slide-up + fade).
///
/// ## Accessibility
/// Honors `accessibilityReduceMotion`: all movement/scale/rotation collapse to a quick opacity
/// fade with a tiny stagger. The reveal stays FAST (~0.4–0.6s end-to-end) so navigation never waits.

// MARK: - Trigger plumbing

private struct TabEntranceTriggerKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

public extension EnvironmentValues {
    /// A monotonic token that advances each time the enclosing tab becomes selected (and once on
    /// cold launch for the default tab). `.tabEntrance` replays its staggered reveal whenever this
    /// changes. Injected per-tab by `MainTabView`.
    var tabEntranceTrigger: Int {
        get { self[TabEntranceTriggerKey.self] }
        set { self[TabEntranceTriggerKey.self] = newValue }
    }
}

public extension View {
    /// Drive the tab-entrance replay for everything inside this view. Pass the token that advances
    /// when this tab becomes selected. See ``TabEntrance``.
    func tabEntranceTrigger(_ token: Int) -> some View {
        environment(\.tabEntranceTrigger, token)
    }
}

// MARK: - Signature styles

public enum TabEntranceStyle: Equatable, Sendable {
    /// Today — fade + slide-up (~16pt) + subtle scale (0.96→1), sections cascading top→bottom.
    case cascade
    /// Today's family grid — spring overshoot pop, echoing `.stickerSlap`.
    case pop
    /// Memories — a slight rotation settle (±4°→0) + slide-up, like a photo landing on a page.
    case tumble
    /// Lists — slide in from the leading edge, like a checklist writing itself.
    case slideLeading
    /// Home — bloom in (scale 0.9→1 with a gentle overshoot), a plant-growth feel.
    case bloom
    /// Kitchen — rise + settle (slide-up + fade), a "plating" feel.
    case rise
}

// MARK: - The hidden-state + spring recipe per style

private struct EntranceMotion {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var scale: CGFloat = 1
    var rotation: Double = 0
    var anchor: UnitPoint = .center
    var animation: Animation = .spring(response: 0.5, dampingFraction: 0.72)
    var stagger: Double = 0.05

    /// Reduce-Motion: no movement — a quick, lightly-staggered opacity fade only.
    static let reduced = EntranceMotion(
        animation: .easeOut(duration: 0.22), stagger: 0.02
    )

    static func make(_ style: TabEntranceStyle, index: Int) -> EntranceMotion {
        switch style {
        case .cascade:
            return EntranceMotion(
                dy: 16, scale: 0.96,
                animation: .spring(response: 0.5, dampingFraction: 0.72), stagger: 0.05
            )
        case .pop:
            // Sticker-slap overshoot: low damping so it springs past 1 and settles.
            return EntranceMotion(
                dy: 10, scale: 0.6,
                animation: .spring(response: 0.42, dampingFraction: 0.56), stagger: 0.05
            )
        case .tumble:
            // Alternate the lean by index so pages tumble onto the page from both sides.
            let lean: Double = (index % 2 == 0) ? -4.5 : 4.5
            return EntranceMotion(
                dy: 20, scale: 0.97, rotation: lean, anchor: .top,
                animation: .spring(response: 0.55, dampingFraction: 0.70), stagger: 0.06
            )
        case .slideLeading:
            return EntranceMotion(
                dx: -30,
                anchor: .leading,
                animation: .spring(response: 0.48, dampingFraction: 0.80), stagger: 0.045
            )
        case .bloom:
            return EntranceMotion(
                dy: 8, scale: 0.9,
                animation: .spring(response: 0.5, dampingFraction: 0.62), stagger: 0.055
            )
        case .rise:
            return EntranceMotion(
                dy: 24, scale: 0.98,
                animation: .spring(response: 0.5, dampingFraction: 0.75), stagger: 0.05
            )
        }
    }
}

// MARK: - The modifier

public struct TabEntrance: ViewModifier {
    let style: TabEntranceStyle
    let index: Int

    @Environment(\.tabEntranceTrigger) private var trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var lastTrigger: Int?

    public init(style: TabEntranceStyle, index: Int) {
        self.style = style
        self.index = max(0, index)
    }

    public func body(content: Content) -> some View {
        let motion = reduceMotion ? EntranceMotion.reduced : EntranceMotion.make(style, index: index)
        content
            .opacity(revealed ? 1 : 0)
            .scaleEffect(revealed ? 1 : motion.scale, anchor: motion.anchor)
            .rotationEffect(.degrees(revealed ? 0 : motion.rotation), anchor: motion.anchor)
            .offset(x: revealed ? 0 : motion.dx, y: revealed ? 0 : motion.dy)
            .onChange(of: trigger, initial: true) { _, newValue in
                // Dedupe: a freshly-instantiated tab can see both the initial fire and its first
                // token bump with the same value — reveal exactly once per distinct token.
                guard lastTrigger != newValue else { return }
                lastTrigger = newValue
                play(motion)
            }
    }

    private func play(_ motion: EntranceMotion) {
        // Snap to hidden (no animation), then animate in on the next runloop so re-selecting a tab
        // whose view is already on-screen still replays cleanly.
        revealed = false
        let delay = motion.stagger * Double(index)
        DispatchQueue.main.async {
            withAnimation(motion.animation.delay(delay)) { revealed = true }
        }
    }
}

public extension View {
    /// Tag this view as part of its tab's signature load-in. `index` sets its place in the stagger
    /// (0 = first). Replays whenever the tab is (re)selected. See ``TabEntrance``.
    func tabEntrance(_ style: TabEntranceStyle = .cascade, index: Int) -> some View {
        modifier(TabEntrance(style: style, index: index))
    }
}
