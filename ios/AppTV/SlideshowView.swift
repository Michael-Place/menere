import SwiftUI

/// The flagship ambient screensaver: a full-screen, slow-drifting, crossfading slideshow of family
/// photos — "The Frame, but ours". Once the TV is connected this is the resting experience.
///
/// - Each frame holds ~7s, shuffled (by `ScrapbookModel`) and looping.
/// - Ken-Burns: every frame slowly scales + pans over its whole life (`KenBurnsFrame`).
/// - Crossfade: the outgoing/incoming frames dissolve over ~1.4s (opacity transition on `.id`).
/// - A subtle "¡Bacán!" corner wordmark + an optional caption sit over a bottom scrim.
struct SlideshowView: View {
    @State private var model: ScrapbookModel
    @State private var index = 0
    @State private var timer: Timer?

    /// ~7s on screen, ~1.4s of that spent crossfading into the next.
    private let holdSeconds: Double = 7.0
    private let crossfadeSeconds: Double = 1.4

    init(hid: String) {
        _model = State(initialValue: ScrapbookModel(hid: hid))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch model.state {
            case .loading:
                GatheringView()
            case .live, .sample:
                slideshow
            }
        }
        .task {
            await model.load()
            startTimer()
        }
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - Slideshow

    @ViewBuilder
    private var slideshow: some View {
        let frames = model.frames
        ZStack {
            if let frame = current(in: frames) {
                KenBurnsFrame(image: frame.image)
                    .id(frame.id)
                    .transition(.opacity)
                    .ignoresSafeArea()

                // Bottom scrim + caption.
                VStack {
                    Spacer()
                    if let caption = frame.caption {
                        HStack {
                            Text(caption)
                                .font(.system(.title2, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                            Spacer()
                        }
                        .padding(.horizontal, 80)
                        .padding(.bottom, 70)
                        .id(frame.id + "-cap")
                        .transition(.opacity)
                    }
                }
                .ignoresSafeArea()
            }

            // Corner wordmark.
            VStack {
                HStack {
                    Spacer()
                    Text("¡Bacán!")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
                        .padding(.trailing, 70)
                        .padding(.top, 60)
                }
                Spacer()
            }
            .ignoresSafeArea()

            // A quiet note when we're on placeholders (Storage unavailable / no photos yet).
            if case let .sample(reason) = model.state {
                VStack {
                    Spacer()
                    Text(reason)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 22).padding(.vertical, 12)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(.bottom, 24)
                }
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: crossfadeSeconds), value: currentID(in: frames))
    }

    private func current(in frames: [ScrapbookModel.Frame]) -> ScrapbookModel.Frame? {
        guard !frames.isEmpty else { return nil }
        return frames[index % frames.count]
    }

    private func currentID(in frames: [ScrapbookModel.Frame]) -> String {
        current(in: frames)?.id ?? "none"
    }

    // MARK: - Advance timer

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: holdSeconds, repeats: true) { _ in
            Task { @MainActor in
                guard !model.frames.isEmpty else { return }
                index = (index + 1) % model.frames.count
            }
        }
    }
}

// MARK: - Ken-Burns frame

/// One photo, aspect-fill, slowly scaling + panning for its whole life on screen. Each instance picks
/// a fresh random drift so successive frames don't feel mechanical.
private struct KenBurnsFrame: View {
    let image: UIImage

    @State private var animateIn = false
    private let drift = Drift.random()

    var body: some View {
        GeometryReader { geo in
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(animateIn ? drift.endScale : drift.startScale)
                .offset(x: animateIn ? drift.endOffset.width : drift.startOffset.width,
                        y: animateIn ? drift.endOffset.height : drift.startOffset.height)
                .clipped()
                .onAppear {
                    withAnimation(.easeInOut(duration: 12.0)) { animateIn = true }
                }
        }
    }

    struct Drift {
        var startScale: CGFloat
        var endScale: CGFloat
        var startOffset: CGSize
        var endOffset: CGSize

        static func random() -> Drift {
            let pan: CGFloat = 60
            func off() -> CGSize { .init(width: .random(in: -pan...pan), height: .random(in: -pan...pan)) }
            return Drift(
                startScale: .random(in: 1.04...1.10),
                endScale: .random(in: 1.14...1.22),
                startOffset: off(),
                endOffset: off()
            )
        }
    }
}

// MARK: - Gathering (first-load) view

private struct GatheringView: View {
    var body: some View {
        VStack(spacing: 32) {
            ProgressView().scaleEffect(2.0).tint(.white)
            Text("Gathering your family photos…")
                .font(.system(.title2, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
