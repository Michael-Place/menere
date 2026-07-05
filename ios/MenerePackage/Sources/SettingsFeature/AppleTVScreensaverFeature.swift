import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import Photos
import PhotoCurationClient
import StorageClient
import SwiftUI
import UserDomain

/// P27-T0 (real build) — **Apple TV screensaver** setup + one-tap photo sync.
///
/// tvOS has no third-party screensaver API, so the only path to "our family on the living-room TV"
/// is Photos: the app CURATES the family's best pet / plant (kids later) shots into a **regular**
/// Photos album — `PhotoCurationClient` proves PhotoKit can create + fill that freely — and the user
/// points the Apple TV screensaver at it with a one-time step. New photos then flow automatically via
/// iCloud Photos sync (see `PhotoCuration-FINDINGS.md`).
///
/// This screen: (1) a warm explainer of the one-time TV setup, (2) category toggles for what to
/// include, (3) a "Sync family photos now" button that gathers the care-item photos from Firebase
/// Storage and publishes them to the "Bacán — TV" album, with progress + a "Synced N" result + the
/// album's live count. Deduplicated so repeated syncs never re-add the same photo.
@Reducer
public struct AppleTVScreensaverReducer {
    /// The regular Photos album the Apple TV screensaver points at. Matches the spike + FINDINGS.
    static let albumName = "Bacán — TV"
    /// UserDefaults key holding the Storage paths already published to the album, so a second sync
    /// only adds NEW photos. Namespaced by album; a reinstall clears it alongside the local library.
    static let syncedPathsKey = "tvScreensaver.syncedPhotoPaths.v1"

    @ObservableState
    public struct State: Equatable {
        /// Include plant photos (`CareKind.plant`).
        var includePlants = true
        /// Include pet photos (`CareKind.pet`).
        var includePets = true
        /// Include kids' moments — the family **memory** photos (`households/{hid}/memories`). P27-T1
        /// flipped this from "coming soon" to working.
        var includeKids = true
        /// Presents the full-screen **"Play on TV"** ambient slideshow.
        var showSlideshow = false
        /// Live authorization for the Photos library (drives the denied/allowed copy).
        var authStatus: PHAuthorizationStatus = .notDetermined
        /// A sync is in flight — disables the button + shows progress.
        var isSyncing = false
        /// Human progress line while syncing ("Gathering photos…", "Publishing 4 photos…").
        var progress: String?
        /// How many photos the *last* sync added (nil until a sync completes).
        var lastSyncedCount: Int?
        /// The album's current asset count (nil until known).
        var albumCount: Int?
        /// Set when Photos access is denied/restricted — shows the Settings deep-link.
        var accessDenied = false
        /// Guards the auto-sync-on-open so it fires at most once per time the screen is shown
        /// (a re-entrant `.task` or a fresh auth resolve won't kick off a second sync).
        var didAutoSync = false

        public init() {}

        /// `true` when at least one category is selected — the sync button needs something to gather.
        var canSync: Bool { includePlants || includePets || includeKids }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case authResolved(PHAuthorizationStatus, albumCount: Int)
        case syncTapped
        case playTapped
        case progressed(String)
        case syncFinished(added: Int, albumCount: Int)
        case accessDenied
        case binding(BindingAction<State>)
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        guard let hid = user?.householdId, !hid.isEmpty else { return nil }
        return hid
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                return .run { send in
                    @Dependency(\.photoCuration) var photoCuration
                    let status = photoCuration.addOnlyAuthorizationStatus()
                    // Only re-query the album when we can actually read it (needs read access).
                    let count = (status == .authorized || status == .limited)
                        ? await photoCuration.albumAssetCount(Self.albumName)
                        : 0
                    await send(.authResolved(status, albumCount: count))
                }

            case let .authResolved(status, count):
                state.authStatus = status
                state.accessDenied = status == .denied || status == .restricted
                if status == .authorized || status == .limited { state.albumCount = count }
                // Auto-sync-on-open: keep the TV album fresh without a tap — but ONLY when setup
                // already looks done. That means (a) Photos access is already granted (we never
                // prompt unsolicited on open) and (b) we've built the album before (it has photos,
                // or a prior sync recorded paths). `didAutoSync` + the `.syncTapped` guards keep it
                // from double-running.
                let accessGranted = status == .authorized || status == .limited
                let setupComplete = count > 0 || !Self.loadSyncedPaths().isEmpty
                if accessGranted, setupComplete, !state.didAutoSync, !state.isSyncing, state.canSync {
                    state.didAutoSync = true
                    return .send(.syncTapped)
                }
                return .none

            case .syncTapped:
                guard !state.isSyncing, state.canSync, let hid = hid() else { return .none }
                state.isSyncing = true
                state.lastSyncedCount = nil
                state.progress = "Preparing…"
                let includePlants = state.includePlants
                let includePets = state.includePets
                let includeKids = state.includeKids
                return .run { send in
                    @Dependency(\.photoCuration) var photoCuration
                    @Dependency(\.storage) var storage
                    @Dependency(\.persistence) var persistence
                    @Dependency(\.analytics) var analytics

                    // 1. Ensure Photos access (one-time system prompt on first run).
                    var status = photoCuration.addOnlyAuthorizationStatus()
                    if status != .authorized && status != .limited {
                        status = await photoCuration.requestAddAccess()
                    }
                    guard status == .authorized || status == .limited else {
                        await send(.accessDenied)
                        return
                    }

                    // 2. Ensure the album exists.
                    _ = await photoCuration.ensureAlbum(Self.albumName)

                    // 3. Gather the family's plant/pet care photos + (when Kids' moments is on) the
                    // memory photos (READ-ONLY on app data).
                    await send(.progressed("Gathering photos…"))
                    let items = (try? await persistence.careItems(hid)) ?? []
                    let wantedKinds: Set<CareKind> = {
                        var s = Set<CareKind>()
                        if includePlants { s.insert(.plant) }
                        if includePets { s.insert(.pet) }
                        return s
                    }()
                    let carePaths: [String] = items
                        .filter { wantedKinds.contains($0.kind) }
                        .compactMap(\.photoPath)
                        .filter { !$0.isEmpty }

                    // Kids' moments: every memory's photos (households/{hid}/memories → photoPaths).
                    let memoryPaths: [String] = includeKids
                        ? ((try? await persistence.memories(hid)) ?? []).flatMap(\.photoPaths).filter { !$0.isEmpty }
                        : []

                    // Combined candidates, deduped by path (a memory photo and a care photo never collide,
                    // but a memory could list the same path twice).
                    var seenCandidate = Set<String>()
                    let candidatePaths: [String] = (carePaths + memoryPaths).filter { seenCandidate.insert($0).inserted }

                    // 4. Dedup: skip anything already published to the album.
                    let alreadySynced = Self.loadSyncedPaths()
                    let newPaths = candidatePaths.filter { !alreadySynced.contains($0) }
                    // How many of the newly-syncing photos are kids' moments (for the tv_kids_synced signal).
                    let memoryPathSet = Set(memoryPaths)
                    let newKidsCount = newPaths.filter { memoryPathSet.contains($0) }.count

                    guard !newPaths.isEmpty else {
                        // Nothing new — just re-report the album's current count.
                        let count = await photoCuration.albumAssetCount(Self.albumName)
                        analytics.log("tv_screensaver_synced", ["count": "0"])
                        await send(.syncFinished(added: 0, albumCount: count))
                        return
                    }

                    // 5. Download the bytes (best-effort; a failed download is simply skipped).
                    await send(.progressed("Downloading \(newPaths.count) photo\(newPaths.count == 1 ? "" : "s")…"))
                    var datas: [Data] = []
                    var downloadedPaths: [String] = []
                    for path in newPaths {
                        if let data = try? await storage.downloadData(path) {
                            datas.append(data)
                            downloadedPaths.append(path)
                        }
                    }

                    guard !datas.isEmpty else {
                        let count = await photoCuration.albumAssetCount(Self.albumName)
                        analytics.log("tv_screensaver_synced", ["count": "0"])
                        await send(.syncFinished(added: 0, albumCount: count))
                        return
                    }

                    // 6. Publish to the album.
                    await send(.progressed("Publishing \(datas.count) photo\(datas.count == 1 ? "" : "s")…"))
                    let result = await photoCuration.addImages(datas, Self.albumName)

                    // 7. Record what landed so the next sync doesn't re-add them. addImages is
                    // transactional (a single performChanges block), so a positive count means all
                    // of `downloadedPaths` were saved.
                    if result.addedCount > 0 {
                        Self.saveSyncedPaths(alreadySynced.union(downloadedPaths))
                    }
                    analytics.log("tv_screensaver_synced", ["count": String(result.addedCount)])
                    if includeKids && newKidsCount > 0 {
                        analytics.log("tv_kids_synced", ["count": String(newKidsCount)])
                    }
                    await send(.syncFinished(added: result.addedCount, albumCount: result.albumAssetCount))
                }

            case .playTapped:
                state.showSlideshow = true
                return .none

            case let .progressed(line):
                state.progress = line
                return .none

            case let .syncFinished(added, count):
                state.isSyncing = false
                state.progress = nil
                state.lastSyncedCount = added
                state.albumCount = count
                state.authStatus = .authorized
                state.accessDenied = false
                return .none

            case .accessDenied:
                state.isSyncing = false
                state.progress = nil
                state.accessDenied = true
                return .none

            case .binding:
                return .none
            }
        }
    }

    // MARK: - Dedup persistence (local, per-install)

    static func loadSyncedPaths() -> Set<String> {
        let arr = UserDefaults.standard.stringArray(forKey: syncedPathsKey) ?? []
        return Set(arr)
    }

    static func saveSyncedPaths(_ paths: Set<String>) {
        UserDefaults.standard.set(Array(paths), forKey: syncedPathsKey)
    }
}

public struct AppleTVScreensaverView: View {
    @Bindable var store: StoreOf<AppleTVScreensaverReducer>
    @Environment(\.openURL) private var openURL

    public init(store: StoreOf<AppleTVScreensaverReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                heroSection
                playSection
                setupStepsSection
                categoriesSection
                syncSection
                if store.accessDenied { deniedSection }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Apple TV screensaver")
            .navigationBarTitleDisplayMode(.inline)
            .task { store.send(.task) }
            .fullScreenCover(isPresented: $store.showSlideshow) {
                AmbientSlideshow()
            }
        }
    }

    // MARK: Sections

    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "tv.fill")
                        .font(.title)
                        .foregroundStyle(Color.bacanGreen)
                    Text("Your family, drifting across the big screen")
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                }
                Text("Turn your Apple TV's idle screensaver into a slideshow of Fajita, Sprinkle, and the plants. We gather the photos into an album called \u{201C}\(AppleTVScreensaverReducer.albumName)\u{201D} — you point the TV at it once, and new photos flow automatically after that.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .listRowBackground(Color.sky.opacity(0.18))
        }
    }

    private var playSection: some View {
        Section {
            Button {
                store.send(.playTapped)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play on TV")
                            .fontWeight(.semibold)
                        Text("AirPlay-mirror an ambient family slideshow, right now")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.terracotta)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityIdentifier("tv-play-button")
        } footer: {
            Text("No setup needed — plays inside Bacán. Swipe into Control Center and Screen Mirror to your Apple TV to fill the big screen.")
        }
    }

    private var setupStepsSection: some View {
        Section {
            stepRow(1, "On your Apple TV, open Settings \u{2192} General \u{2192} Screen Saver.")
            stepRow(2, "Choose Type \u{2192} Photos, then pick the \u{201C}\(AppleTVScreensaverReducer.albumName)\u{201D} album.")
            stepRow(3, "Make sure the Apple TV is signed into the same family iCloud as this phone (with iCloud Photos on) — that's how new photos reach the TV.")
        } header: {
            Text("One-time setup on the TV")
        } footer: {
            Text("You only do this once, ever. After that, Bacán tops up the album on its own each time you open this screen — and there's a Sync button below whenever you want to nudge it.")
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.terracotta, in: .circle)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.ink)
        }
        .padding(.vertical, 2)
    }

    private var categoriesSection: some View {
        Section {
            Toggle(isOn: $store.includePlants) {
                Label("Plants", systemImage: "leaf.fill")
                    .foregroundStyle(Color.ink)
            }
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("tv-toggle-plants")

            Toggle(isOn: $store.includePets) {
                Label("Pets", systemImage: "pawprint.fill")
                    .foregroundStyle(Color.ink)
            }
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("tv-toggle-pets")

            Toggle(isOn: $store.includeKids) {
                Label("Kids' moments", systemImage: "figure.and.child.holdinghands")
                    .foregroundStyle(Color.ink)
            }
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("tv-toggle-kids")
        } header: {
            Text("What to include")
        } footer: {
            Text("Pick which family photos land on the TV — pets, plants, and the boys' memories.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                store.send(.syncTapped)
            } label: {
                HStack(spacing: 10) {
                    if store.isSyncing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(store.isSyncing ? (store.progress ?? "Syncing…") : "Sync family photos now")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.bacanGreen)
            .disabled(store.isSyncing || !store.canSync)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityIdentifier("tv-sync-button")

            if let synced = store.lastSyncedCount {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.bacanGreen)
                    Text(syncedResultText(synced))
                        .foregroundStyle(Color.ink)
                }
                .accessibilityIdentifier("tv-sync-result")
            }

            if let count = store.albumCount {
                HStack {
                    Text("\u{201C}\(AppleTVScreensaverReducer.albumName)\u{201D} album")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(count) photo\(count == 1 ? "" : "s")")
                        .foregroundStyle(Color.ink)
                        .fontWeight(.medium)
                }
                .font(.subheadline)
                .accessibilityIdentifier("tv-album-count")
            }
        } footer: {
            Text("First sync will ask for permission to add to your Photos — that's the one-time grant that lets us build the album.")
        }
    }

    private func syncedResultText(_ n: Int) -> String {
        switch n {
        case 0: return "Already up to date — nothing new to add."
        case 1: return "Synced 1 photo to the TV album."
        default: return "Synced \(n) photos to the TV album."
        }
    }

    private var deniedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Photos access is off")
                    .font(.headline)
                    .foregroundStyle(Color.terracotta)
                Text("Bacán needs permission to add photos to build the TV album. Turn it on in Settings, then come back and tap Sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Text("Open Settings")
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.bacanGreen)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tv-open-settings")
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview {
    AppleTVScreensaverView(
        store: Store(initialState: AppleTVScreensaverReducer.State()) {
            AppleTVScreensaverReducer()
        }
    )
}
