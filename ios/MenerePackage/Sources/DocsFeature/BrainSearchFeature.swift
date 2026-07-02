import ComposableArchitecture
import FamilyDomain
import Foundation
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// A single ranked search hit. `matchContext` is populated only when the match is *exclusively* in
/// the document's extracted text (so the UI can show why an otherwise-unlabelled doc surfaced).
public struct BrainSearchResult: Equatable, Identifiable {
    public let document: FamilyDomain.Document
    public let matchContext: String?
    public var id: String { document.id }
}

/// The Family-Brain search sheet — presented from the shared toolbar on every tab (like Settings).
///
/// All matching is local/in-memory over the household's documents (fetched once on open); there are
/// no per-keystroke server round-trips. Ranking: title/vendor hits first, then tags/summary, then
/// extracted-text-only hits (which carry a match-context snippet).
@Reducer
public struct BrainSearchReducer {
    @ObservableState
    public struct State: Equatable {
        var query = ""
        /// nil = "All"; otherwise the selected type chip.
        var typeFilter: DocumentType?
        var documents: [FamilyDomain.Document] = []
        var isLoading = false
        @Presents var detail: DocumentDetailReducer.State?

        public init() {}

        /// The ranked results for the current query + filter. Empty query → most-recent docs.
        var results: [BrainSearchResult] {
            BrainSearchReducer.results(documents: documents, query: query, type: typeFilter)
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case documentsLoaded([FamilyDomain.Document])
        case resultTapped(FamilyDomain.Document)
        /// Dismiss the search sheet. The parent (`MainTabReducer`) owns the presentation flag.
        case closeTapped
        case detail(PresentationAction<DocumentDetailReducer.Action>)
        case binding(BindingAction<State>)
    }

    public init() {}

    @Dependency(\.persistence) var persistence

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Each open starts fresh: clear the previous query/filter, then reload the index.
                state.query = ""
                state.typeFilter = nil
                guard let hid = hid() else { return .none }
                state.isLoading = true
                return .run { send in
                    let docs = (try? await persistence.documents(hid)) ?? []
                    await send(.documentsLoaded(docs))
                }

            case let .documentsLoaded(docs):
                state.isLoading = false
                state.documents = docs.sorted { $0.createdAt > $1.createdAt }
                return .none

            case let .resultTapped(doc):
                state.detail = DocumentDetailReducer.State(doc: doc)
                return .none

            case .closeTapped:
                // Handled by the parent (which owns the sheet's presentation flag).
                return .none

            // Keep search results consistent with edits/deletes made from the pushed detail.
            case let .detail(.presented(.delegate(.didChange(doc)))):
                if let idx = state.documents.firstIndex(where: { $0.id == doc.id }) {
                    state.documents[idx] = doc
                }
                return .none

            case let .detail(.presented(.delegate(.didDelete(id)))):
                state.documents.removeAll { $0.id == id }
                return .none

            case .detail, .binding:
                return .none
            }
        }
        .ifLet(\.$detail, action: \.detail) {
            DocumentDetailReducer()
        }
    }

    // MARK: Ranking

    /// The number of most-recent documents shown for an empty query.
    static let recentLimit = 12

    /// Case- and diacritic-insensitive ranked search. Tier 0: title/vendor; tier 1: tags/summary;
    /// tier 2: extracted-text only (carries a match-context snippet). Sorted by tier then recency.
    static func results(documents: [FamilyDomain.Document], query: String, type: DocumentType?) -> [BrainSearchResult] {
        let filtered = type.map { t in documents.filter { $0.type == t } } ?? documents
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            // Empty query → the N most recent (documents are already newest-first).
            return filtered.prefix(recentLimit).map { BrainSearchResult(document: $0, matchContext: nil) }
        }

        struct Ranked { let result: BrainSearchResult; let tier: Int; let createdAt: Date }
        var ranked: [Ranked] = []
        for doc in filtered {
            let inTitle = contains(doc.title, trimmed)
            let inVendor = contains(doc.vendor, trimmed)
            let inTags = doc.tags.contains { contains($0, trimmed) }
            let inSummary = contains(doc.summary, trimmed)
            let inText = contains(doc.extractedText, trimmed)

            let tier: Int
            if inTitle || inVendor { tier = 0 }
            else if inTags || inSummary { tier = 1 }
            else if inText { tier = 2 }
            else { continue }

            // Match-context only when the hit lives *exclusively* in the extracted text.
            let context = (tier == 2) ? snippet(doc.extractedText, trimmed) : nil
            ranked.append(
                Ranked(
                    result: BrainSearchResult(document: doc, matchContext: context),
                    tier: tier,
                    createdAt: doc.createdAt
                )
            )
        }
        return ranked
            .sorted { a, b in a.tier != b.tier ? a.tier < b.tier : a.createdAt > b.createdAt }
            .map(\.result)
    }

    private static func contains(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// A short "…matched in text: '…window…'" snippet around the first extracted-text hit.
    static func snippet(_ text: String?, _ needle: String) -> String? {
        guard let text, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let pad = 24
        let lower = text.index(range.lowerBound, offsetBy: -pad, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(range.upperBound, offsetBy: pad, limitedBy: text.endIndex) ?? text.endIndex
        var fragment = String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
        fragment = fragment.replacingOccurrences(of: "\n", with: " ")
        let prefix = lower > text.startIndex ? "…" : ""
        let suffix = upper < text.endIndex ? "…" : ""
        return "matched in text: “\(prefix)\(fragment)\(suffix)”"
    }
}

public struct BrainSearchView: View {
    @Bindable var store: StoreOf<BrainSearchReducer>
    @FocusState private var searchFocused: Bool

    public init(store: StoreOf<BrainSearchReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                typeChips
                resultsList
            }
            .background(Color.familyCanvas)
            .navigationTitle("Family Brain")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { store.send(.closeTapped) }
                        .accessibilityIdentifier("brain-search-done")
                }
            }
            .navigationDestination(
                item: $store.scope(state: \.detail, action: \.detail)
            ) { detailStore in
                DocumentDetailView(store: detailStore)
            }
            .task {
                store.send(.task)
                searchFocused = true
            }
        }
        .tint(.bacanGreen)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.inkSoft)
            TextField("Search the family brain", text: $store.query)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("brain-search-field")
            if !store.query.isEmpty {
                Button {
                    store.send(.binding(.set(\.query, "")))
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.inkSoft)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var typeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", type: nil)
                ForEach(DocumentType.allCases, id: \.self) { type in
                    chip(title: type.displayName, type: type)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, type: DocumentType?) -> some View {
        let selected = store.typeFilter == type
        return Button {
            store.send(.binding(.set(\.typeFilter, type)))
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? Color.bacanGreen : Color.familySurface, in: Capsule())
                .foregroundStyle(selected ? .white : Color.inkSoft)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("brain-chip-\(type?.rawValue ?? "all")")
    }

    @ViewBuilder
    private var resultsList: some View {
        let results = store.results
        if results.isEmpty {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.largeTitle)
                    .foregroundStyle(Color.inkSoft.opacity(0.5))
                Text(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Nothing filed yet."
                     : "Nothing in the brain for that — yet.")
                    .foregroundStyle(Color.inkSoft)
                    .accessibilityIdentifier("brain-empty-state")
            }
            Spacer()
            Spacer()
        } else {
            List {
                Section {
                    ForEach(results) { result in
                        Button {
                            store.send(.resultTapped(result.document))
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                DocumentRow(doc: result.document) {}
                                if let context = result.matchContext {
                                    Text(context)
                                        .font(.caption2)
                                        .foregroundStyle(Color.inkSoft)
                                        .lineLimit(1)
                                        .accessibilityIdentifier("brain-match-context")
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
        }
    }
}
