import SwiftUI

/// A "polaroid" frame for journal photos: a warm `.surfaceMenere` card around the image with a
/// slightly deeper bottom lip, a `.continuous` corner radius, a soft warm shadow, and a hair of
/// rotation for character. Keep `rotation` tiny (±1–2°) so it reads as handmade, not broken.
public struct PolaroidFrame<Content: View>: View {
    private let rotation: Double
    private let content: Content

    public init(rotation: Double = 0, @ViewBuilder content: () -> Content) {
        self.rotation = rotation
        self.content = content()
    }

    public var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(6)
            .padding(.bottom, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.surfaceMenere)
            )
            .shadow(color: Color.wine.opacity(0.18), radius: 5, x: 0, y: 3)
            .rotationEffect(.degrees(rotation))
    }
}

public extension View {
    /// Wraps the view in a `PolaroidFrame`. `rotation` is in degrees — keep it tiny (±1–2°).
    func polaroid(rotation: Double = 0) -> some View {
        PolaroidFrame(rotation: rotation) { self }
    }
}
