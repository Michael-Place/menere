import ComposableArchitecture
import Foundation
import JournalFeature
import UserDomain
import WineDomain

/// Drives the bottle card — the enriched, provenance-badged render of a resolved `Wine`.
///
/// Phase 1 (this milestone) is a static render of an already-resolved `Wine`. State carries seams
/// reserved for M4 Phase 2 (progressive reveal + threading the captured label image) and M5
/// (Add-to-cellar / Log-tasting actions), which are intentionally not implemented yet.
@Reducer
public struct BottleCardFeature {
    @ObservableState
    public struct State: Equatable {
        /// The resolved, (possibly) enriched wine the card renders.
        public var wine: Wine

        // MARK: M4 Phase 2 seams (unused in Phase 1)

        /// The pre-resolution candidate. Phase 2 uses this to drive a progressive reveal while
        /// enrichment is still in flight.
        public var candidate: WineCandidate?
        /// The captured label image bytes. Phase 2 threads the real captured image through
        /// ScanFeature into the hero block; Phase 1 falls back to `wine.labelImageURL`.
        public var imageData: Data?
        /// Whether enrichment is still resolving. Phase 2 uses this for the shimmer / progressive UI.
        public var isResolving: Bool

        /// M5: the presented journaling form (Add to cellar / Log a tasting), if any.
        @Presents public var destination: Destination.State?

        public init(
            wine: Wine,
            candidate: WineCandidate? = nil,
            imageData: Data? = nil,
            isResolving: Bool = false,
            destination: Destination.State? = nil
        ) {
            self.wine = wine
            self.candidate = candidate
            self.imageData = imageData
            self.isResolving = isResolving
            self.destination = destination
        }
    }

    public enum Action: Equatable {
        case task
        case addToCellarTapped
        case logTastingTapped
        case destination(PresentationAction<Destination.Action>)
    }

    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case addToCellar(BottleFormReducer)
        case logTasting(TastingFormReducer)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .none

            case .addToCellarTapped:
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.destination = .addToCellar(BottleFormReducer.State(wine: state.wine, hid: hid))
                return .none

            case .logTastingTapped:
                @Shared(.user) var user
                guard let uid = user?.id, let hid = user?.householdId else { return .none }
                state.destination = .logTasting(TastingFormReducer.State(wine: state.wine, hid: hid, uid: uid))
                return .none

            case .destination(.presented(.addToCellar(.delegate))),
                 .destination(.presented(.logTasting(.delegate))):
                // saved OR cancelled → dismiss the form. (Persistence happens inside the form reducer.)
                state.destination = nil
                return .none

            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}
