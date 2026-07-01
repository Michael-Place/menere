import SwiftUI

/// A subtle sweeping-highlight shimmer used over `.redacted(reason: .placeholder)` content to signal
/// "loading" while data resolves. The gradient is masked to the content's shape so only the
/// redacted bars shimmer. The highlight is a warm Candle Gold sweep to match the brand.
public struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    public init() {}

    public func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, Color.candleGold.opacity(0.35), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: phase * geo.size.width * 1.6)
                    .mask(content)
                    .allowsHitTesting(false)
                }
            )
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

public extension View {
    /// Apply the loading shimmer. Pair with `.redacted(reason: .placeholder)`.
    /// When `active` is `false` the view is returned unchanged.
    @ViewBuilder
    func shimmering(active: Bool = true) -> some View {
        if active {
            modifier(Shimmer())
        } else {
            self
        }
    }
}
