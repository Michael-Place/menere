import AnalyticsClient
import ComposableArchitecture
import Foundation

/// The family **Memories** tab (P28) — the dedicated home for the family's journal / scrapbook. C1
/// ships this as a SHELL: a warm empty-state placeholder and a disabled "Capture a moment" button.
/// C2 fills it in with the memory model (`households/{hid}/memories`), the scrapbook-page editor,
/// and the timeline. Deliberately a NEW module (not `JournalFeature`, which is the WINE tasting
/// journal) so the two never entangle.
@Reducer
public struct MemoriesReducer {
    @ObservableState
    public struct State: Equatable {
        public init() {}
    }

    public enum Action: Equatable {
        case task
        /// C2 wires this up — the shell button is disabled, but the action exists so the surface is
        /// ready for the capture flow.
        case captureMomentTapped
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { _, action in
            switch action {
            case .task:
                @Dependency(\.analytics) var analytics
                analytics.log("memories_opened")   // P25 telemetry (fire-and-forget)
                return .none
            case .captureMomentTapped:
                // C2: present the scrapbook-page editor. No-op in the shell.
                return .none
            }
        }
    }
}
