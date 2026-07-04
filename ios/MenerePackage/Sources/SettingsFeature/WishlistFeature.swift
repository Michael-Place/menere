import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// "Ideas for Bacán" (P25) — a dead-simple, always-discoverable capture surface presented from the
/// Settings sheet. A text field to drop "I wish it could X", plus the family's existing ideas
/// (text · who · when), newest first. Stored at `households/{hid}/wishlist`, member-gated by the
/// existing rules. Submitting an idea also dogfoods the telemetry (`wishlist_idea_added`).
@Reducer
public struct WishlistReducer {
    @ObservableState
    public struct State: Equatable {
        var ideas: [WishlistIdea] = []
        var draft = ""
        var isLoading = false
        var isSaving = false

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        case loaded([WishlistIdea])
        case addTapped
        case added(WishlistIdea)
        case binding(BindingAction<State>)
    }

    public init() {}

    private func ctx() -> (hid: String, uid: String, name: String)? {
        @Shared(.user) var user
        guard let hid = user?.householdId, let uid = user?.id else { return nil }
        let name = (user?.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (hid, uid, name.isEmpty ? "Someone" : name)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                guard let (hid, _, _) = ctx() else { return .none }
                state.isLoading = true
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let ideas = (try? await persistence.wishlist(hid)) ?? []
                    await send(.loaded(ideas))
                }

            case let .loaded(ideas):
                state.isLoading = false
                state.ideas = ideas
                return .none

            case .addTapped:
                let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isSaving, let (hid, uid, name) = ctx() else { return .none }
                let idea = WishlistIdea(text: text, uid: uid, authorName: name)
                state.isSaving = true
                state.draft = ""
                // Optimistic: show it immediately, newest-first.
                state.ideas.insert(idea, at: 0)
                @Dependency(\.analytics) var analytics
                analytics.log("wishlist_idea_added")   // dogfood the telemetry
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try? await persistence.addWishlistIdea(hid, idea)
                    await send(.added(idea))
                }

            case .added:
                state.isSaving = false
                return .none

            case .binding:
                return .none
            }
        }
    }
}

public struct WishlistView: View {
    @Bindable var store: StoreOf<WishlistReducer>
    @FocusState private var fieldFocused: Bool

    public init(store: StoreOf<WishlistReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("What would make Bacán better?", text: $store.draft, axis: .vertical)
                            .lineLimit(1...4)
                            .focused($fieldFocused)
                            .accessibilityIdentifier("wishlist-field")
                        Button {
                            store.send(.addTapped)
                        } label: {
                            HStack {
                                Image(systemName: "plus.circle.fill")
                                Text("Add")
                            }
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.bacanGreen)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("wishlist-add-button")
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Got an idea? We're all ears. Drop it here and we'll see it.")
                }

                if !store.ideas.isEmpty {
                    Section("Ideas") {
                        ForEach(store.ideas) { idea in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(idea.text).foregroundStyle(Color.ink)
                                Text("\(idea.authorName) · \(idea.at.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else if store.isLoading {
                    Section { ProgressView() }
                } else {
                    Section {
                        Text("No ideas yet — be the first.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Ideas for Bacán")
            .navigationBarTitleDisplayMode(.inline)
            .task { store.send(.task) }
        }
    }
}
