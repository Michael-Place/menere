import AnalyticsClient
import Dependencies
import FamilyDomain
import MenereUI
import PersistenceClient
import Sharing
import StorageClient
import SwiftUI
import UserDomain

/// P27-T1 — the in-app **"Play on TV" ambient slideshow**. A full-screen, auto-advancing slideshow of
/// the family's warmest photos (pets + plants + kids' memories) that the user AirPlay-mirrors to the
/// Apple TV. This is the "prove the magic" tier that rides on the scrapbook work while a native tvOS
/// app (T2) is still ahead.
///
/// Behaviour:
/// - Gathers photo bytes from the SAME sources as the screensaver sync — care-item photos
///   (`PersistenceClient.careItems` → `StorageClient.downloadData`) plus memory photos
///   (`PersistenceClient.memories` → each `photoPaths`) — decoded to `UIImage`, deduped by path.
/// - Auto-advances every ~7s with a gentle **crossfade** and a slow **Ken-Burns** drift (scale + pan).
/// - **Tap anywhere to dismiss.**
/// - **Keeps the screen awake** while playing (`UIApplication.isIdleTimerDisabled`), restored on exit.
/// - Handles "no photos yet" gracefully with a warm empty state.
///
/// It's a plain SwiftUI view (no TCA state) so the big image bytes never live in the reducer — it
/// resolves its clients via `@Dependency` and loads on `.task`.
public struct AmbientSlideshow: View {
    /// One loaded frame — a decoded image plus its Storage path (the dedup + scrapbook seed key).
    struct Frame: Identifiable, Equatable {
        let path: String
        let image: UIImage
        var id: String { path }
    }

    /// Seconds each photo holds before crossfading to the next.
    private static let interval: TimeInterval = 7
    /// Crossfade duration between frames.
    private static let fade: TimeInterval = 1.4

    private let onDismiss: () -> Void

    @Dependency(\.persistence) private var persistence
    @Dependency(\.storage) private var storage
    @Dependency(\.analytics) private var analytics
    @Shared(.user) private var user

    @State private var frames: [Frame] = []
    @State private var index = 0
    @State private var isLoading = true
    /// Drives the Ken-Burns drift for the current frame — toggled on each advance so the animation
    /// re-runs from its resting state every time.
    @State private var drift = false
    @Environment(\.dismiss) private var dismiss

    public init(onDismiss: @escaping () -> Void = {}) {
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                loadingState
            } else if frames.isEmpty {
                emptyState
            } else {
                slideshow
            }

            // A soft dismiss affordance, top-trailing — the whole screen is tappable, this just hints it.
            VStack {
                HStack {
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding()
                    }
                    .accessibilityLabel("Close slideshow")
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .statusBarHidden(true)
        .task { await load() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Slideshow

    private var slideshow: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Array(frames.enumerated()), id: \.element.id) { i, frame in
                    if i == index {
                        Image(uiImage: frame.image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            // Ken-Burns: start slightly zoomed + offset, drift to a different rest.
                            .scaleEffect(drift ? 1.12 : 1.05)
                            .offset(
                                x: drift ? -kenBurnsX(frame) : kenBurnsX(frame),
                                y: drift ? -kenBurnsY(frame) : kenBurnsY(frame)
                            )
                            .clipped()
                            .transition(.opacity)
                            .id(frame.id)
                    }
                }

                // Warm caption plate anchoring the family identity, bottom-leading.
                VStack {
                    Spacer()
                    HStack {
                        Text("¡Bacán! · Family")
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    .padding(24)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: Self.fade), value: index)
        .task(id: frames.count) { await runLoop() }
    }

    /// Deterministic Ken-Burns pan magnitudes seeded by the photo path, so each frame drifts its own
    /// gentle direction (never jitters between renders).
    private func kenBurnsX(_ frame: Frame) -> CGFloat { CGFloat(Scrapbook.tilt(for: frame.path + "x", max: 22)) }
    private func kenBurnsY(_ frame: Frame) -> CGFloat { CGFloat(Scrapbook.tilt(for: frame.path + "y", max: 16)) }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.white)
            Text("Gathering the family album…")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundStyle(.white.opacity(0.6))
            Text("No family photos yet")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
            Text("Add photos to your pets, plants, or a memory, then come back to play them on the TV.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Done", action: close)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.top, 8)
        }
        .padding()
    }

    // MARK: Behaviour

    private func close() {
        UIApplication.shared.isIdleTimerDisabled = false
        onDismiss()
        dismiss()
    }

    /// The auto-advance loop — crossfades to the next frame every `interval`. Also kicks the initial
    /// Ken-Burns drift for frame 0. Cancels cleanly when the view goes away (structured `.task`).
    private func runLoop() async {
        guard frames.count > 0 else { return }
        // Start frame 0 drifting.
        withAnimation(.easeInOut(duration: Self.interval + Self.fade)) { drift = true }
        while frames.count > 1 {
            try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: Self.fade)) {
                index = (index + 1) % frames.count
            }
            // Re-arm the Ken-Burns drift for the new frame.
            drift = false
            withAnimation(.easeInOut(duration: Self.interval + Self.fade)) { drift = true }
        }
    }

    /// Gather + decode all family photos (care + memories), deduped by Storage path. Best-effort:
    /// a failed download or non-image byte is simply skipped, so one bad photo never blanks the show.
    private func load() async {
        analytics.log("tv_slideshow_played")
        defer { isLoading = false }
        guard let hid = user?.householdId, !hid.isEmpty else { return }

        // Care photos (pets + plants).
        let careItems = (try? await persistence.careItems(hid)) ?? []
        let carePaths = careItems.compactMap(\.photoPath).filter { !$0.isEmpty }

        // Memory photos (kids' moments).
        let memories = (try? await persistence.memories(hid)) ?? []
        let memoryPaths = memories.flatMap(\.photoPaths).filter { !$0.isEmpty }

        // Interleave a little so the show doesn't front-load one category, deduping by path.
        var seen = Set<String>()
        let ordered = (carePaths + memoryPaths).filter { seen.insert($0).inserted }

        var loaded: [Frame] = []
        for path in ordered {
            guard let data = try? await storage.downloadData(path), let image = UIImage(data: data) else { continue }
            loaded.append(Frame(path: path, image: image))
        }
        frames = loaded.shuffled()
    }
}
