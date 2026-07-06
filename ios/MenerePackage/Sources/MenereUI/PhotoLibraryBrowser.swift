import Dependencies
import Photos
import PhotoLibraryClient
import SwiftUI
import UIKit

// MARK: - FL1 — the in-app photo browser ("the family lens")
//
// A warm, family-styled front door onto the real photo library (via ``PhotoLibraryClient``). Where
// the memory editor's `PhotosPicker` is Apple's locked-down one-shot sheet, this browser lets the
// family BROWSE + SEARCH their whole library: a lazy thumbnail grid, filter chips
// (All · Favorites · Recents · by month · albums), and multi-select with an "Add N to memory" action.
//
// It hands the caller back the *selected asset IDs*; the memory editor then loads the full images
// (`loadFullImage`) and uploads them through the existing StorageClient path — persistence unchanged.

/// The active filter for ``PhotoLibraryBrowser``.
private enum BrowserFilter: Equatable {
    case all
    case favorites
    case recents
    case person(FaceTag)      // FL4 — "Photos of {name}" (a device-local face tag)
    case month(Date)          // first-of-month anchor
    case album(PhotoAlbum)

    var chipTitle: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .recents: return "Recents"
        case let .person(tag): return tag.memberName.split(separator: " ").first.map(String.init) ?? tag.memberName
        case let .month(date): return BrowserFilter.monthFormatter.string(from: date)
        case let .album(album): return album.title
        }
    }

    static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
}

/// The rich, browse-your-whole-library photo picker. Present it as a sheet; it calls `onAdd` with the
/// chosen asset `localIdentifier`s and dismisses itself.
public struct PhotoLibraryBrowser: View {
    /// Called with the selected asset ids when the family taps "Add N to memory".
    private let onAdd: ([String]) -> Void
    /// FL4 — called with a `HouseholdMember.id` when the family taps a "People" (Photos of {name}) chip,
    /// so the presenting feature can log `photos_of_person_viewed` (MenereUI has no analytics of its own).
    private let onPersonViewed: ((String) -> Void)?

    public init(
        onPersonViewed: ((String) -> Void)? = nil,
        onAdd: @escaping ([String]) -> Void
    ) {
        self.onPersonViewed = onPersonViewed
        self.onAdd = onAdd
    }

    @Dependency(\.photoLibrary) private var photoLibrary
    @Dependency(\.faceTagStore) private var faceTagStore
    @Environment(\.dismiss) private var dismiss

    @State private var status: PHAuthorizationStatus = .notDetermined
    @State private var assets: [PhotoAsset] = []
    @State private var albums: [PhotoAlbum] = []
    @State private var months: [Date] = []
    @State private var people: [FaceTag] = []
    @State private var selection: Set<String> = []
    @State private var filter: BrowserFilter = .all
    @State private var isLoading = false
    @State private var isRequesting = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    public var body: some View {
        NavigationStack {
            Group {
                switch status {
                case .authorized, .limited:
                    grantedBody
                case .denied, .restricted:
                    deniedGate
                default:
                    notDeterminedGate
                }
            }
            .background(Color.familyCanvas)
            .navigationTitle("Your photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("photo-browser-cancel")
                }
            }
        }
        .task { await bootstrap() }
    }

    // MARK: Granted (authorized or limited)

    private var grantedBody: some View {
        VStack(spacing: 0) {
            if status == .limited { limitedBanner }
            filterChips
            grid
            if !selection.isEmpty { addBar }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.all)
                chip(.favorites)
                chip(.recents)
                // FL4 — "Photos of {name}" chips for each device-local face tag, leading the row.
                ForEach(people) { personChip($0) }
                ForEach(months, id: \.self) { chip(.month($0)) }
                ForEach(albums) { chip(.album($0)) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.familyCanvas)
    }

    private func chip(_ f: BrowserFilter) -> some View {
        let selected = filter == f
        return Button {
            guard filter != f else { return }
            filter = f
            Task { await reloadAssets() }
        } label: {
            Text(f.chipTitle)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(selected ? .white : Color.bacanGreen)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? Color.bacanGreen : Color.bacanGreen.opacity(0.14))
                )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("photo-filter-\(f.chipTitle)")
    }

    /// FL4 — a "Photos of {name}" chip: a tiny face thumbnail + the person's first name.
    private func personChip(_ tag: FaceTag) -> some View {
        let f = BrowserFilter.person(tag)
        let selected = filter == f
        return Button {
            guard filter != f else { return }
            filter = f
            onPersonViewed?(tag.memberID)
            Task { await reloadAssets() }
        } label: {
            HStack(spacing: 6) {
                if let data = tag.sampleThumbnail, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(selected ? .white : Color.bacanGreen)
                }
                Text(f.chipTitle)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(selected ? .white : Color.bacanGreen)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.bacanGreen : Color.bacanGreen.opacity(0.14))
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("photo-person-\(tag.memberID)")
    }

    @ViewBuilder
    private var grid: some View {
        if isLoading {
            Spacer()
            ProgressView().tint(Color.bacanGreen)
            Spacer()
        } else if assets.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(assets) { asset in
                        PhotoThumbnailCell(
                            assetID: asset.id,
                            isFavorite: asset.isFavorite,
                            isSelected: selection.contains(asset.id),
                            selectionIndex: selectionIndex(asset.id)
                        )
                        .onTapGesture { toggle(asset.id) }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(Color.bacanGreen.opacity(0.5))
            Text("No photos here yet")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color.ink)
            Text("Try another filter — or snap something wonderful.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var addBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                onAdd(orderedSelection())
                dismiss()
            } label: {
                Text("Add \(selection.count) to memory")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .accessibilityIdentifier("photo-browser-add")
        }
        .background(.ultraThinMaterial)
    }

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .foregroundStyle(Color.terracotta)
            Text("You've shared some of your photos.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.ink)
            Spacer()
            Button("Manage") { presentLimitedPicker() }
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .accessibilityIdentifier("photo-manage-selection")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.marigold.opacity(0.16))
    }

    // MARK: Gates

    private var notDeterminedGate: some View {
        photoGate(
            symbol: "photo.stack",
            title: "Let Bacán see your photos",
            message: "Pick family moments straight from your library to add to a memory. You can share your whole library or just a few.",
            buttonTitle: isRequesting ? "Asking…" : "Choose photos to share",
            action: { Task { await request() } }
        )
    }

    private var deniedGate: some View {
        photoGate(
            symbol: "lock.fill",
            title: "Photos are turned off",
            message: "To browse your library into memories, let Bacán see your photos in Settings.",
            buttonTitle: "Open Settings",
            action: openSettings
        )
    }

    private func photoGate(
        symbol: String,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(Color.bacanGreen)
            Text(title)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).padding(.vertical, 13)
                    .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
            .disabled(isRequesting)
            .accessibilityIdentifier("photo-gate-button")
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Selection

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    /// The 1-based tap order for a selected asset (shown in the badge), or nil if unselected.
    private func selectionIndex(_ id: String) -> Int? {
        guard selection.contains(id) else { return nil }
        return orderedSelection().firstIndex(of: id).map { $0 + 1 }
    }

    /// Selection in grid order (newest-first, matching the fetch order) so "Add N" is deterministic.
    private func orderedSelection() -> [String] {
        assets.map(\.id).filter { selection.contains($0) }
    }

    // MARK: Loading

    private func bootstrap() async {
        status = photoLibrary.authorizationStatus()
        if status == .authorized || status == .limited {
            await loadEverything()
        }
    }

    private func request() async {
        isRequesting = true
        status = await photoLibrary.requestAccess()
        isRequesting = false
        if status == .authorized || status == .limited {
            await loadEverything()
        }
    }

    /// Initial load: albums, the month buckets, the FL4 face tags, and the current filter's assets.
    private func loadEverything() async {
        isLoading = true
        people = faceTagStore.all()
        async let albumsTask = photoLibrary.fetchAlbums()
        let all = await photoLibrary.fetchAssets(PhotoAssetFilter(limit: 2000))
        albums = await albumsTask
        months = monthBuckets(from: all)
        assets = applyClientCap(all)
        isLoading = false
    }

    private func reloadAssets() async {
        isLoading = true
        // FL4 — a person filter replays the tag's stored asset ids (order preserved) rather than a query.
        if case let .person(tag) = filter {
            assets = applyClientCap(await photoLibrary.assetsByIDs(tag.assetIDs))
        } else {
            assets = applyClientCap(await photoLibrary.fetchAssets(filterQuery()))
        }
        isLoading = false
    }

    private func filterQuery() -> PhotoAssetFilter {
        switch filter {
        case .all:
            return PhotoAssetFilter(limit: 2000)
        case .favorites:
            return PhotoAssetFilter(onlyFavorites: true, limit: 2000)
        case .recents:
            let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            return PhotoAssetFilter(dateRange: since...Date(), limit: 2000)
        case .person:
            // Handled specially in `reloadAssets` (stored asset ids); this branch is never reached.
            return PhotoAssetFilter(limit: 2000)
        case let .month(anchor):
            let cal = Calendar.current
            let start = cal.date(from: cal.dateComponents([.year, .month], from: anchor)) ?? anchor
            let end = cal.date(byAdding: DateComponents(month: 1, second: -1), to: start) ?? anchor
            return PhotoAssetFilter(dateRange: start...end, limit: 2000)
        case let .album(album):
            return PhotoAssetFilter(albumID: album.id, limit: 2000)
        }
    }

    private func applyClientCap(_ list: [PhotoAsset]) -> [PhotoAsset] { list }

    /// The distinct year-months present in the library (newest first, capped), for the month chips.
    private func monthBuckets(from list: [PhotoAsset]) -> [Date] {
        let cal = Calendar.current
        var seen = Set<Date>()
        var result: [Date] = []
        for asset in list {
            guard let date = asset.creationDate,
                  let anchor = cal.date(from: cal.dateComponents([.year, .month], from: date)) else { continue }
            if seen.insert(anchor).inserted { result.append(anchor) }
            if result.count >= 12 { break }
        }
        return result
    }

    // MARK: System hooks

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func presentLimitedPicker() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        // Present over the top-most controller (the browser sheet).
        var top = root
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }
}

// MARK: - Thumbnail cell

/// A single lazy-loaded thumbnail in the browser grid — decoded via ``PhotoLibraryClient`` and cached
/// in a shared `NSCache` (H1 spirit: downsample at decode time, paint a warm cache hit on frame one,
/// no re-decode when a cell scrolls back). A selected cell dims + shows a numbered check badge.
private struct PhotoThumbnailCell: View {
    let assetID: String
    let isFavorite: Bool
    let isSelected: Bool
    let selectionIndex: Int?

    @Dependency(\.photoLibrary) private var photoLibrary
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.bacanGreen.opacity(0.08))
                        .overlay(ProgressView().controlSize(.small).tint(Color.bacanGreen))
                }

                if isFavorite {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .shadow(radius: 1)
                                .padding(5)
                            Spacer()
                        }
                    }
                }

                if isSelected {
                    Color.bacanGreen.opacity(0.28)
                    VStack {
                        HStack {
                            Spacer()
                            selectionBadge
                                .padding(5)
                        }
                        Spacer()
                    }
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .task(id: assetID) { await load(targetSide: side) }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var selectionBadge: some View {
        ZStack {
            Circle().fill(Color.bacanGreen)
            Circle().strokeBorder(.white, lineWidth: 1.5)
            if let selectionIndex {
                Text("\(selectionIndex)")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func load(targetSide: CGFloat) async {
        let key = assetID as NSString
        if let cached = PhotoThumbnailCache.shared.object(forKey: key) {
            image = cached
            return
        }
        let size = CGSize(width: max(targetSide, 120), height: max(targetSide, 120))
        guard let data = await photoLibrary.loadThumbnail(assetID, size),
              let ui = UIImage(data: data) else { return }
        PhotoThumbnailCache.shared.setObject(ui, forKey: key)
        image = ui
    }
}

/// Process-wide thumbnail cache for the browser grid (bounded so a big library can't balloon memory).
private enum PhotoThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()
}
