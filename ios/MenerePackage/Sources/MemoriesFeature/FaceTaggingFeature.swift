import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import Foundation
import PhotoLibraryClient

// MARK: - FL4 — "People": tag a discovered face → a family member
//
// Apple won't hand us its People face NAMES, so ¡Bacán! groups faces on-device (``PhotoLibraryClient/scanFaces``)
// and lets the family tag a group ONCE. The mapping is saved device-locally (``FaceTagStore``) — never to
// Firestore. Tagged people then power the "Photos of {name}" filter in the photo browser.

@Reducer
public struct FaceTaggingReducer {
    public enum ScanPhase: Equatable, Sendable {
        case idle
        case scanning
        case done
    }

    @ObservableState
    public struct State: Equatable {
        public var members: [HouseholdMember]
        /// Photo read-authorization (reuses the Memories tab's distilled state).
        public var photoAuth: PhotoAuthState = .unknown
        public var scanPhase: ScanPhase = .idle
        /// Discovered, still-untagged face groups (largest first).
        public var clusters: [FaceCluster] = []
        /// Already-tagged people (device-local), most recent first.
        public var tagged: [FaceTag] = []
        /// The cluster whose "Who is this?" picker is open.
        public var pickerCluster: FaceCluster?
        public var isRequesting = false

        public init(members: [HouseholdMember]) {
            self.members = members
        }

        /// Members not yet tagged to a face — the picker options (tagging is one face-tag per member).
        public var untaggedMembers: [HouseholdMember] {
            let taggedIDs = Set(tagged.map(\.memberID))
            return members.filter { !taggedIDs.contains($0.id) }
        }
    }

    public enum Action: Equatable {
        case task
        case authLoaded(PhotoAuthState)
        case connectTapped
        case scanTapped
        case scanned([FaceCluster])
        case clusterTapped(FaceCluster)
        case assignTapped(memberID: String)
        case pickerDismissed
        case untagTapped(memberID: String)
    }

    public init() {}

    @Dependency(\.photoLibrary) var photoLibrary
    @Dependency(\.faceTagStore) var faceTagStore
    @Dependency(\.analytics) var analytics

    /// First-cut cap — favorites + recents only, never the whole library.
    static let scanCap = 200

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.tagged = faceTagStore.all()
                return .run { send in
                    await send(.authLoaded(PhotoAuthState(photoLibrary.authorizationStatus())))
                }

            case let .authLoaded(auth):
                state.photoAuth = auth
                return .none

            case .connectTapped:
                state.isRequesting = true
                return .run { send in
                    let auth = PhotoAuthState(await photoLibrary.requestAccess())
                    await send(.authLoaded(auth))
                    if auth == .ready { await send(.scanTapped) }
                }

            case .scanTapped:
                guard state.photoAuth == .ready, state.scanPhase != .scanning else {
                    // Not authorized yet — route through the connect prompt instead.
                    if state.photoAuth != .ready { return .send(.connectTapped) }
                    return .none
                }
                state.isRequesting = false
                state.scanPhase = .scanning
                return .run { send in
                    await send(.scanned(photoLibrary.scanFaces(Self.scanCap)))
                }
                .cancellable(id: CancelID.scan, cancelInFlight: true)

            case let .scanned(clusters):
                state.scanPhase = .done
                // Hide clusters whose sample asset is already covered by an existing tag (best-effort de-dupe).
                let taggedAssets = Set(state.tagged.flatMap(\.assetIDs))
                state.clusters = clusters.filter { !taggedAssets.contains($0.sampleAssetID) }
                analytics.log("faces_scanned", [
                    "clusters": String(clusters.count),
                    "faces": String(clusters.reduce(0) { $0 + $1.faceCount }),
                ])
                return .none

            case let .clusterTapped(cluster):
                state.pickerCluster = cluster
                return .none

            case let .assignTapped(memberID):
                guard let cluster = state.pickerCluster,
                      let member = state.members.first(where: { $0.id == memberID }) else { return .none }
                faceTagStore.tag(memberID, member.name, cluster.assetIDs, cluster.sampleFaceThumbnail)
                state.pickerCluster = nil
                state.clusters.removeAll { $0.id == cluster.id }
                state.tagged = faceTagStore.all()
                analytics.log("face_tagged", ["photos": String(cluster.assetIDs.count)])
                return .none

            case .pickerDismissed:
                state.pickerCluster = nil
                return .none

            case let .untagTapped(memberID):
                faceTagStore.untag(memberID)
                state.tagged = faceTagStore.all()
                return .none
            }
        }
    }

    private enum CancelID { case scan }
}
