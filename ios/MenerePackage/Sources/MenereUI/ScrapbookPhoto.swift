import SwiftUI
import UIKit

// MARK: - Deterministic seed helpers

/// Namespace for the "Layered collage" scrapbook look — deterministic seeding + a shared paper
/// texture, so every photo tilts the SAME way on every render (seeded by a stable id/path) and never
/// jitters between frames.
public enum Scrapbook {
    /// FNV-1a 64-bit — a *stable* hash across launches (unlike `String.hashValue`, which is salted
    /// per process, so it can't seed a "never changes" rotation).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }

    /// A stable `Double` in `0..<1` for a seed string.
    static func unit(_ s: String) -> Double {
        Double(hash(s) % 100_000) / 100_000.0
    }

    /// The stable tilt (degrees) for a photo, seeded by `seed`, within `±max`. Same seed → same tilt
    /// forever. Pass a real photo id / storage path so it survives relayouts and navigation.
    public static func tilt(for seed: String, max: Double = 2.5) -> Double {
        (unit(seed) * 2 - 1) * max
    }
}

// MARK: - Palette (warm kraft mat + ink-kraft corners)

extension Color {
    /// The warm kraft/cream paper mat a scrapbook photo is mounted on.
    static let scrapbookMat = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(hex: 0x2B2724) : UIColor(hex: 0xF3ECDC)
    })
    /// The little corner mounts — a warm kraft/ink tone, like real album photo corners.
    static let scrapbookCorner = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark ? UIColor(hex: 0x6E6152) : UIColor(hex: 0x9B8A6E)
    })
}

// MARK: - Shared paper-grain texture (generated ONCE, reused everywhere)

/// A tiny tileable noise tile, rendered a single time and cached. Every `ScrapbookPhoto` overlays the
/// SAME `UIImage` (tiled), so the "paper grain" costs one bitmap for the whole app — a 32-plant strip
/// stays smooth.
enum ScrapbookTexture {
    static let grain: UIImage = makeGrain(size: 96)

    /// Deterministic splitmix64 so the tile looks identical every launch.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func makeGrain(size: Int) -> UIImage {
        let dim = CGSize(width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: dim, format: format)
        return renderer.image { ctx in
            var rng = SplitMix64(state: 0xB4C0_FFEE)
            let cg = ctx.cgContext
            let count = (size * size) / 3
            for _ in 0..<count {
                let x = CGFloat(rng.next() % UInt64(size))
                let y = CGFloat(rng.next() % UInt64(size))
                let dark = rng.next() & 1 == 0
                let alpha = CGFloat(rng.next() % 60) / 1000.0   // up to ~0.06
                cg.setFillColor((dark ? UIColor.black : UIColor.white).withAlphaComponent(alpha).cgColor)
                cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
}

// MARK: - Photo-corner mount

/// A single album photo-corner: a right triangle whose right angle sits in the top-left of its frame
/// and whose hypotenuse crosses over the photo's corner — exactly how a real mounting corner tucks a
/// print onto the page.
private struct PhotoCornerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct CornerMount: View {
    var length: CGFloat
    var body: some View {
        PhotoCornerShape()
            .fill(
                LinearGradient(
                    colors: [Color.scrapbookCorner, Color.scrapbookCorner.opacity(0.72)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay(
                PhotoCornerShape().stroke(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .frame(width: length, height: length)
    }
}

/// Places the four corner mounts on top of a clipped photo. Rotated so each right angle lands in its
/// own corner.
private struct CornerMounts: View {
    var length: CGFloat
    var body: some View {
        ZStack {
            CornerMount(length: length)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            CornerMount(length: length).rotationEffect(.degrees(90))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            CornerMount(length: length).rotationEffect(.degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            CornerMount(length: length).rotationEffect(.degrees(270))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ScrapbookPhoto

/// Frames ANY image content in the "Layered collage" scrapbook style: a warm kraft paper mat with a
/// subtle procedural grain, four little album photo-corner mounts holding the print, a soft shadow
/// for lift, an optional caption + date on the mat below (album-label feel), and a **deterministic**
/// gentle tilt seeded by `seed` (so it never jitters — pass a stable id/path). Pass `rotation: 0` to
/// force it flat.
///
/// The photo window fills the caller's width and derives its height from `aspect` (width ÷ height).
/// When `image` is `nil` the `fallback` glyph is shown on the mat, still fully framed.
public struct ScrapbookPhoto<Fallback: View>: View {
    private let image: UIImage?
    private let seed: String
    private let caption: String?
    private let date: Date?
    private let forcedRotation: Double?
    private let aspect: CGFloat
    private let maxTilt: Double
    private let fallback: Fallback

    public init(
        image: UIImage?,
        seed: String,
        caption: String? = nil,
        date: Date? = nil,
        rotation: Double? = nil,
        aspect: CGFloat = 1,
        maxTilt: Double = 2.5,
        @ViewBuilder fallback: () -> Fallback
    ) {
        self.image = image
        self.seed = seed
        self.caption = caption
        self.date = date
        self.forcedRotation = rotation
        self.aspect = aspect
        self.maxTilt = maxTilt
        self.fallback = fallback()
    }

    private var tilt: Double { forcedRotation ?? Scrapbook.tilt(for: seed, max: maxTilt) }
    private var hasLabel: Bool { (caption?.isEmpty == false) || date != nil }

    public var body: some View {
        VStack(spacing: hasLabel ? 8 : 0) {
            photoWindow
            if hasLabel { label }
        }
        .padding(14)
        .padding(.bottom, hasLabel ? 2 : 0)
        .background(mat)
        .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 5)
        .rotationEffect(.degrees(tilt))
    }

    private var photoWindow: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    fallback
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(CornerMounts(length: 22))
    }

    private var mat: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.scrapbookMat)
            .overlay(
                Image(uiImage: ScrapbookTexture.grain)
                    .resizable(resizingMode: .tile)
                    .opacity(0.6)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .allowsHitTesting(false)
            )
    }

    private var label: some View {
        VStack(spacing: 1) {
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            if let date {
                Text(date, format: .dateTime.month(.abbreviated).day().year())
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ScrapbookThumb (lightweight strip variant)

/// The mini scrapbook chip for dense strips (Home-hub plants/pets): the kraft mat + corner mounts +
/// seeded tilt + soft shadow, sized to `side`, but WITHOUT the paper-grain overlay or caption — kept
/// deliberately cheap so a scroll of ~32 stays smooth. `clip` lets pets read as circular avatars.
public struct ScrapbookThumb<Content: View>: View {
    public enum Clip { case roundedRect(CGFloat), circle }

    private let seed: String
    private let side: CGFloat
    private let clip: Clip
    private let maxTilt: Double
    private let content: Content

    public init(
        seed: String,
        side: CGFloat,
        clip: Clip = .roundedRect(6),
        maxTilt: Double = 3,
        @ViewBuilder content: () -> Content
    ) {
        self.seed = seed
        self.side = side
        self.clip = clip
        self.maxTilt = maxTilt
        self.content = content()
    }

    private var tilt: Double { Scrapbook.tilt(for: seed, max: maxTilt) }

    public var body: some View {
        content
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay(cornerMounts)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.scrapbookMat)
            )
            .shadow(color: .black.opacity(0.16), radius: 3, x: 0, y: 2)
            .rotationEffect(.degrees(tilt))
    }

    private var shape: RoundedRectangle {
        switch clip {
        case let .roundedRect(r): return RoundedRectangle(cornerRadius: r, style: .continuous)
        case .circle: return RoundedRectangle(cornerRadius: side / 2, style: .continuous)
        }
    }

    // Small, subtle corner ticks — only shown on rectangular chips (they'd read wrong on a circle).
    @ViewBuilder private var cornerMounts: some View {
        if case .roundedRect = clip {
            CornerMounts(length: max(9, side * 0.22)).opacity(0.9)
        }
    }
}

// MARK: - ScrapbookCollage

/// One item in a `ScrapbookCollage`.
public struct ScrapbookItem: Identifiable, Equatable {
    public let id: String
    public let image: UIImage?
    public let caption: String?
    public let date: Date?

    public init(id: String, image: UIImage?, caption: String? = nil, date: Date? = nil) {
        self.id = id
        self.image = image
        self.caption = caption
        self.date = date
    }
}

/// Lays a small set of photos out in the layered-collage feel — varied sizes, gentle overlap, and
/// alternating (deterministic) tilts. Renders 1 as a single centered `ScrapbookPhoto` and 2–N as an
/// overlapping fan. Every offset/tilt is seeded by the item id, so it never jitters. `fallback` backs
/// any item with no image.
public struct ScrapbookCollage<Fallback: View>: View {
    private let items: [ScrapbookItem]
    private let baseWidth: CGFloat
    private let fallback: (ScrapbookItem) -> Fallback

    public init(
        items: [ScrapbookItem],
        baseWidth: CGFloat = 200,
        @ViewBuilder fallback: @escaping (ScrapbookItem) -> Fallback
    ) {
        self.items = items
        self.baseWidth = baseWidth
        self.fallback = fallback
    }

    public var body: some View {
        if items.count <= 1 {
            if let item = items.first {
                ScrapbookPhoto(
                    image: item.image, seed: item.id, caption: item.caption, date: item.date, aspect: 1
                ) { fallback(item) }
                .frame(width: baseWidth)
            }
        } else {
            ZStack {
                ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { index, item in
                    let n = Double(Scrapbook.unit(item.id))
                    let sign: Double = index.isMultiple(of: 2) ? 1 : -1
                    let scale = 0.82 + 0.18 * n                       // varied sizes
                    let dx = sign * baseWidth * (0.14 + 0.10 * n)     // gentle horizontal fan
                    let dy = (n - 0.5) * baseWidth * 0.18             // gentle vertical scatter
                    ScrapbookPhoto(
                        image: item.image, seed: item.id, aspect: 1, maxTilt: 4
                    ) { fallback(item) }
                    .frame(width: baseWidth * scale)
                    .offset(x: dx, y: dy)
                    .zIndex(Double(index))
                }
            }
            .frame(width: baseWidth * 1.5, height: baseWidth * 1.15)
        }
    }
}

#if DEBUG
private struct ScrapbookDemo: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ScrapbookPhoto(image: nil, seed: "monstera", caption: "Monstera", date: .now, aspect: 1.25) {
                    ZStack {
                        LinearGradient(colors: [.bacanGreen.opacity(0.35), .bacanGreen.opacity(0.12)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "leaf.fill").font(.system(size: 56)).foregroundStyle(Color.bacanGreen.opacity(0.6))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(0..<8, id: \.self) { i in
                            ScrapbookThumb(seed: "p\(i)", side: 44) {
                                ZStack { Color.bacanGreen.opacity(0.15); Image(systemName: "leaf.fill").foregroundStyle(Color.bacanGreen) }
                            }
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal)
                }
            }
            .padding(.vertical, 40)
        }
        .background(Color.familyCanvas)
    }
}

#Preview("Scrapbook") { ScrapbookDemo() }
#endif
