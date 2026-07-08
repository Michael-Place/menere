import SwiftUI

/// The wine-stack type ramp, exposed as composable `View` modifiers. These once rendered New York
/// serif for the "Cellar & Candlelight" look; the cellar now shares the Bacán identity, so they map
/// onto the family's chunky SF Rounded (matching `familyTitle`/`familyDisplay` below). The helper
/// names are kept so every wine-stack call site stays untouched. Defaults set brand colors where it
/// reads well, but callers can override by applying their own `.foregroundStyle(_:)` afterward.
public extension View {
    /// Large rounded title — e.g. a screen's hero producer name (Bacán's family display weight).
    func wineTitle() -> some View {
        self
            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.ink)
    }

    /// A wine's producer/name in rounded semibold. Defaults to `.title2`; pass a style to scale it.
    func wineName(_ style: Font.TextStyle = .title2) -> some View {
        self.font(.system(style, design: .rounded).weight(.semibold))
    }

    /// The cuvée line — soft rounded in a muted ink (the family's quiet-subtitle voice).
    func cuvee() -> some View {
        self
            .font(.system(.title3, design: .rounded).weight(.medium))
            .foregroundStyle(Color.inkSoft)
    }

    /// A small-caps-ish producer label — tracked, uppercased rounded in soft ink.
    func producerLabel() -> some View {
        self
            .font(.system(.subheadline, design: .rounded).weight(.medium))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Color.inkSoft)
    }
}

/// The family identity type ramp — chunky SF Rounded, "record-label energy". Lives alongside the
/// serif wine helpers above; family surfaces use these, the Cellar stack keeps the serif ones.
public extension View {
    /// Large rounded heavy display — greetings and section heroes.
    func familyDisplay() -> some View {
        self
            .font(.system(.largeTitle, design: .rounded).weight(.heavy))
            .foregroundStyle(Color.ink)
    }

    /// Rounded semibold header. Defaults to `.title3`; pass a style to scale it.
    func familyTitle(_ style: Font.TextStyle = .title3) -> some View {
        self
            .font(.system(style, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.ink)
    }
}
