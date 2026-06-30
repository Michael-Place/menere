import SwiftUI

/// The Menere serif (New York) type ramp, exposed as composable `View` modifiers. Defaults set
/// brand colors where it reads well, but callers can override by applying their own
/// `.foregroundStyle(_:)` afterward.
public extension View {
    /// Large serif title — e.g. a screen's hero producer name.
    func wineTitle() -> some View {
        self
            .font(.system(.largeTitle, design: .serif).weight(.semibold))
            .foregroundStyle(Color.ink)
    }

    /// A wine's producer/name in serif. Defaults to `.title2`; pass a style to scale it.
    func wineName(_ style: Font.TextStyle = .title2) -> some View {
        self.font(.system(style, design: .serif).weight(.semibold))
    }

    /// The cuvée line — italic serif in a soft ink.
    func cuvee() -> some View {
        self
            .font(.system(.title3, design: .serif).italic())
            .foregroundStyle(Color.inkSoft)
    }

    /// A small-caps-ish producer label — tracked, uppercased serif in soft ink.
    func producerLabel() -> some View {
        self
            .font(.system(.subheadline, design: .serif))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Color.inkSoft)
    }
}
