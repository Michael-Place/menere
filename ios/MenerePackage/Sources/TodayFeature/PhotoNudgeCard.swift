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

    // MARK: The nudge (authorized, fresh batch) — a slim inline prompt, not a full card

    /// Demoted (declutter pass) from a full card with a preview strip + big button to a single slim
    /// row: one thumbnail, a one-line prompt, a compact "Make a memory" chip, and a quiet dismiss. It
    /// sits inline under the greeting so it invites without competing with the day's real priorities.
    private func nudgeCard(_ nudge: PhotoNudge) -> some View {
        HStack(spacing: 10) {
            if let first = nudge.thumbnailAssetIDs.first {
                PhotoNudgeThumbnail(assetID: first, side: 40)
            } else {
                Image(systemName: "photo.badge.plus.fill")
                    .font(.title3)
                    .foregroundStyle(Color.marigold)
                    .frame(width: 40, height: 40)
            }

            Button {
                store.send(.photoNudgeTapped)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(nudgeLine(nudge.newCount))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text("Tap to make a memory 📸")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color.bacanGreen)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-photo-nudge-make-memory")

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
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
        .accessibilityIdentifier("today-photo-nudge")
    }

    /// "12 new photos" (grammatical for a single photo too).
    private func nudgeLine(_ count: Int) -> String {
        count == 1 ? "1 new photo" : "\(count) new photos"
    }

    // MARK: The soft opt-in (Photos not asked yet) — a slim one-line prompt

    private var softOptInCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.subheadline)
                .foregroundStyle(Color.bacanGreen)
            Text("Surface new photos as memories?")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button {
                store.send(.photoNudgeSurfaceDismissed)
            } label: {
                Text("Later")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.inkSoft)
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-photo-nudge-later")

            Button {
                store.send(.photoNudgeSurfaceTapped)
            } label: {
                Text("Sure")
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("today-photo-nudge-surface")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
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

}

// MARK: - Preview thumbnail

/// One lazily-loaded preview thumbnail in the nudge strip — decoded off `PhotoLibraryClient` and kept
/// in a small process-wide cache so scrolling Today doesn't re-decode. Read-only (FL2 never writes).
private struct PhotoNudgeThumbnail: View {
    let assetID: String
    var side: CGFloat = 60

    @Dependency(\.photoLibrary) private var photoLibrary
    @State private var image: UIImage?

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
