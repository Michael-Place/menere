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

        /// M5: the presented journaling form (Add to cellar / Log a tasting / Edit), if any.
        @Presents public var destination: Destination.State?

        /// UX2a: owned-bottle delete confirmation dialog.
        @Presents public var confirmDelete: ConfirmationDialogState<Action.ConfirmDelete>?

        /// When set, the card renders an owned bottle: shows the on-hand facts and suppresses
        /// Add-to-on-hand. Nil = scan path, unchanged.
        public var ownedBottle: Bottle? = nil

        /// This wine's journal entries (tastings), newest first — surfaced read-only on the card so a
        /// bottle reads as "the wine + its journal". Passed in by the presenter (the Wine root); the
        /// scan path leaves it empty.
        public var journalEntries: [Tasting] = []

        /// D2: a monotonic bump counter fired when a bottle is successfully added to the cellar. The
        /// view observes changes to play the wax-seal celebration + a success haptic. Transient UI
        /// trigger only — not persisted, not part of the constructable surface.
        public var sealStamp: Int = 0

        public init(
            wine: Wine,
            candidate: WineCandidate? = nil,
            imageData: Data? = nil,
            isResolving: Bool = false,
            destination: Destination.State? = nil,
            ownedBottle: Bottle? = nil,
            journalEntries: [Tasting] = []
        ) {
            self.wine = wine
            self.candidate = candidate
            self.imageData = imageData
            self.isResolving = isResolving
            self.destination = destination
            self.ownedBottle = ownedBottle
            self.journalEntries = journalEntries
        }
    }

    public enum Action: Equatable {
        case task
        case addToCellarTapped
        case logTastingTapped
        case editTapped
        case deleteTapped
        case confirmDelete(PresentationAction<ConfirmDelete>)
        case destination(PresentationAction<Destination.Action>)
        case delegate(Delegate)

        public enum ConfirmDelete: Equatable { case confirm }

        public enum Delegate: Equatable {
            case bottleDeleted(String)
            case bottleUpdated(Bottle)
        }
    }

    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case addToCellar(BottleFormReducer)
        case logTasting(TastingFormReducer)
        case editBottle(BottleFormReducer)
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

            case .editTapped:
                guard let bottle = state.ownedBottle else { return .none }
                @Shared(.user) var user
                guard let hid = user?.householdId else { return .none }
                state.destination = .editBottle(
                    BottleFormReducer.State(editing: bottle, wine: state.wine, hid: hid)
                )
                return .none

            case .deleteTapped:
                guard state.ownedBottle != nil else { return .none }
                state.confirmDelete = ConfirmationDialogState {
                    TextState("Delete this bottle?")
                } actions: {
                    ButtonState(role: .destructive, action: .confirm) {
                        TextState("Delete")
                    }
                    ButtonState(role: .cancel) {
                        TextState("Cancel")
                    }
                }
                return .none

            case .confirmDelete(.presented(.confirm)):
                guard let bottle = state.ownedBottle else { return .none }
                return .send(.delegate(.bottleDeleted(bottle.id)))

            case .destination(.presented(.editBottle(.delegate(.saved(let bottle))))):
                state.destination = nil
                return .send(.delegate(.bottleUpdated(bottle)))

            case .destination(.presented(.editBottle(.delegate(.cancelled)))):
                state.destination = nil
                return .none

            case .destination(.presented(.addToCellar(.delegate(.saved)))):
                // Bottle tucked into the cellar → dismiss the form and fire the wax-seal celebration.
                // (Persistence happens inside the form reducer.)
                state.destination = nil
                state.sealStamp += 1
                return .none

            case .destination(.presented(.addToCellar(.delegate))),
                 .destination(.presented(.logTasting(.delegate))):
                // cancelled (or logTasting saved/cancelled) → just dismiss the form.
                state.destination = nil
                return .none

            case .confirmDelete, .delegate:
                return .none

            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
        .ifLet(\.$confirmDelete, action: \.confirmDelete)
    }
}
