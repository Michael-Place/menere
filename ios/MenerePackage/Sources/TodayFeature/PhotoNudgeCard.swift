import ComposableArchitecture
import MenereUI
import PhotoLibraryClient
import SwiftUI
import UIKit

// MARK: - FL2 — the new-photo nudge card
//
// Bacán noticing you added photos and gently inviting you to journal them. When Photos is authorized
// and a fresh batch has landed since the acknowledged watermark, a warm card offers a preview strip +
// "Make a memory" (→ the rich `PhotoLibraryBrowser`, whose selection is handed to the existing memory-
// create path). When Photos hasn't been asked yet, a softer one-time opt-in. After saving, a fleeting
// "Saved to Memories ✨" confirmation. Dismissing or acting advances the watermark so it never re-nags.

struct PhotoNudgeCard: View {
    @Bindable var store: StoreOf<TodayReducer>

    var body: some View {
        Group {
            if store.photoNudgeSaving {
                savingCard
            } else if let count = store.photoNudgeSavedCount {
                savedCard(count)
            } else if let nudge = store.photoNudge, nudge.newCount > 0 {
                nudgeCard(nudge)
            } else if store.photoNudgeNotDetermined {
                softOptInCard
            }
        }
    }

    // MARK: The nudge (authorized, fresh batch)

    private func nudgeCard(_ nudge: PhotoNudge) -> some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "photo.badge.plus.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.marigold)
                Text("New photos")
                    .familyTitle(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
                Button {
                    store.send(.photoNudgeDismissed)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.inkSoft)
                        .padding(6)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Not now")
                .accessibilityIdentifier("today-photo-nudge-dismiss")
            }

            Text(nudgeLine(nudge.newCount))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !nudge.thumbnailAssetIDs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(nudge.thumbnailAssetIDs, id: \.self) { id in
                        PhotoNudgeThumbnail(assetID: id)
                    }
                    Spacer(minLength: 0)
                }
            }

            Button {
                store.send(.photoNudgeTapped)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                    Text("Make a memory")
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-photo-nudge-make-memory")
        }
        .accessibilityIdentifier("today-photo-nudge")
    }

    /// "You added 12 new photos — want to save any as a memory? 📸" (grammatical for a single photo too).
    private func nudgeLine(_ count: Int) -> String {
        let noun = count == 1 ? "1 new photo" : "\(count) new photos"
        return "You added \(noun) — want to save any as a memory? 📸"
    }

    // MARK: The soft opt-in (Photos not asked yet)

    private var softOptInCard: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.subheadline)
                    .foregroundStyle(Color.bacanGreen)
                Text("Your photos")
                    .familyTitle(.headline)
                    .foregroundStyle(Color.ink)
                Spacer()
            }
            Text("Let Bacán surface new photos so you can turn them into memories?")
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    store.send(.photoNudgeSurfaceDismissed)
                } label: {
                    Text("Maybe later")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Capsule(style: .continuous).fill(Color.bacanGreen.opacity(0.12)))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("today-photo-nudge-later")

                Button {
                    store.send(.photoNudgeSurfaceTapped)
                } label: {
                    Text("Sure")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Capsule(style: .continuous).fill(Color.bacanGreen))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("today-photo-nudge-surface")
            }
        }
        .accessibilityIdentifier("today-photo-nudge-optin")
    }

    // MARK: Saving / saved states

    private var savingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Color.bacanGreen)
            Text("Tucking your photos into a memory…")
                .foregroundStyle(Color.inkSoft)
            Spacer()
        }
        .font(.system(.subheadline, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("today-photo-nudge-saving")
    }

    private func savedCard(_ count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.bacanGreen)
            Text(count == 1 ? "Saved a photo to Memories ✨" : "Saved \(count) photos to Memories ✨")
                .foregroundStyle(Color.inkSoft)
            Spacer()
        }
        .font(.system(.subheadline, design: .rounded))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("today-photo-nudge-saved")
    }

    // MARK: Card chrome (matches Today's familySurface cards)

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.familySurface)
            )
    }
}

// MARK: - Preview thumbnail

/// One lazily-loaded preview thumbnail in the nudge strip — decoded off `PhotoLibraryClient` and kept
/// in a small process-wide cache so scrolling Today doesn't re-decode. Read-only (FL2 never writes).
private struct PhotoNudgeThumbnail: View {
    let assetID: String

    @Dependency(\.photoLibrary) private var photoLibrary
    @State private var image: UIImage?

    private let side: CGFloat = 60

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.bacanGreen.opacity(0.08))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: assetID) { await load() }
    }

    private func load() async {
        let key = assetID as NSString
        if let cached = PhotoNudgeThumbnailCache.shared.object(forKey: key) {
            image = cached
            return
        }
        let size = CGSize(width: side, height: side)
        guard let data = await photoLibrary.loadThumbnail(assetID, size),
              let ui = UIImage(data: data) else { return }
        PhotoNudgeThumbnailCache.shared.setObject(ui, forKey: key)
        image = ui
    }
}

private enum PhotoNudgeThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        return cache
    }()
}
