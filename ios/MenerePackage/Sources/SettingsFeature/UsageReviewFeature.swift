import ComposableArchitecture
import Dependencies
import DependenciesMacros
import FirebaseFunctions
import Foundation
import MenereUI
import SwiftUI

// MARK: - Client

/// One concrete suggestion in a usage review (a UX fix + why it's grounded in the data).
public struct UsageSuggestion: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public var title: String
    public var why: String

    public init(title: String, why: String) {
        self.title = title
        self.why = why
    }
}

/// The AI weekly usage review returned by the `reviewUsage` callable (P25-C2).
public struct UsageReview: Equatable, Sendable {
    public var summary: String
    public var topFeatures: [String]
    public var underusedFeatures: [String]
    public var frictionSignals: [String]
    public var suggestions: [UsageSuggestion]
    public var windowDays: Int
    public var eventCount: Int
    public var isSparse: Bool

    public init(
        summary: String,
        topFeatures: [String],
        underusedFeatures: [String],
        frictionSignals: [String],
        suggestions: [UsageSuggestion],
        windowDays: Int,
        eventCount: Int,
        isSparse: Bool
    ) {
        self.summary = summary
        self.topFeatures = topFeatures
        self.underusedFeatures = underusedFeatures
        self.frictionSignals = frictionSignals
        self.suggestions = suggestions
        self.windowDays = windowDays
        self.eventCount = eventCount
        self.isSparse = isSparse
    }
}

/// Wraps the `reviewUsage` HTTPS callable. The household + analytics are derived server-side from
/// the caller; the client just asks for a review over an optional window.
@DependencyClient
public struct UsageReviewClient: Sendable {
    public var review: @Sendable (_ windowDays: Int?) async throws -> UsageReview
}

public enum UsageReviewClientError: Error, Equatable {
    case invalidResponse
}

extension UsageReviewClient: DependencyKey {
    public static let liveValue = UsageReviewClient(
        review: { windowDays in
            let callable = Functions.functions(region: "us-central1").httpsCallable("reviewUsage")
            var payload: [String: Any] = [:]
            if let windowDays { payload["windowDays"] = windowDays }
            let result = try await callable.call(payload)
            guard
                let data = result.data as? [String: Any],
                let summary = data["summary"] as? String,
                !summary.isEmpty
            else { throw UsageReviewClientError.invalidResponse }

            let strings: (String) -> [String] = { key in
                (data[key] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            let suggestions: [UsageSuggestion] = (data["suggestions"] as? [[String: Any]] ?? []).compactMap {
                guard let title = ($0["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return nil }
                let why = ($0["why"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return UsageSuggestion(title: title, why: why)
            }
            return UsageReview(
                summary: summary,
                topFeatures: strings("topFeatures"),
                underusedFeatures: strings("underusedFeatures"),
                frictionSignals: strings("frictionSignals"),
                suggestions: suggestions,
                windowDays: (data["windowDays"] as? Int) ?? 7,
                eventCount: (data["eventCount"] as? Int) ?? 0,
                isSparse: (data["isSparse"] as? Bool) ?? true
            )
        }
    )

    public static let testValue = UsageReviewClient()
}

extension DependencyValues {
    public var usageReview: UsageReviewClient {
        get { self[UsageReviewClient.self] }
        set { self[UsageReviewClient.self] = newValue }
    }
}

// MARK: - Reducer

/// "How we're using Bacán" (P25-C2) — the weekly usage review sheet. Self-contained (its own
/// reducer + view, mirroring the wishlist feature) so it plugs into Settings additively. Calls the
/// `reviewUsage` callable (Claude reads the family's own analytics), shows the latest review, and
/// re-runs it on refresh with a shimmer while thinking. Honest about early/sparse data.
@Reducer
public struct UsageReviewReducer {
    @ObservableState
    public struct State: Equatable {
        var review: UsageReview?
        var isLoading = false
        var errorMessage: String?

        public init() {}
    }

    public enum Action: Equatable {
        case task
        case refreshTapped
        case reviewResponse(TaskResult<UsageReview>)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // Don't re-fetch if we already have a review (sheet re-appearing).
                guard state.review == nil, !state.isLoading else { return .none }
                return run(&state)

            case .refreshTapped:
                guard !state.isLoading else { return .none }
                return run(&state)

            case let .reviewResponse(.success(review)):
                state.isLoading = false
                state.errorMessage = nil
                state.review = review
                return .none

            case .reviewResponse(.failure):
                state.isLoading = false
                // Keep any prior review on screen; only show an error when we have nothing.
                if state.review == nil {
                    state.errorMessage = "Couldn't put the review together just now — give it another tap in a moment."
                }
                return .none
            }
        }
    }

    private func run(_ state: inout State) -> Effect<Action> {
        state.isLoading = true
        state.errorMessage = nil
        return .run { send in
            @Dependency(\.usageReview) var usageReview
            await send(.reviewResponse(TaskResult { try await usageReview.review(nil) }))
        }
    }
}

// MARK: - View

public struct UsageReviewView: View {
    let store: StoreOf<UsageReviewReducer>

    public init(store: StoreOf<UsageReviewReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            List {
                if let review = store.review {
                    loadedContent(review)
                } else if store.isLoading {
                    loadingContent
                } else if let error = store.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("How we're using Bacán")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.send(.refreshTapped)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                    .accessibilityIdentifier("usage-review-refresh")
                }
            }
            .task { store.send(.task) }
        }
    }

    @ViewBuilder
    private func loadedContent(_ review: UsageReview) -> some View {
        // The "still early" banner — the telemetry is only days old.
        if review.isSparse {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(Color.marigold)
                    Text("Still early — this fills in as the family uses the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }

        Section {
            Text(review.summary)
                .foregroundStyle(Color.ink)
                .shimmering(active: store.isLoading)
                .accessibilityIdentifier("usage-review-summary")
        } header: {
            Text(windowLabel(review))
        }

        if !review.topFeatures.isEmpty {
            labelSection("What's getting used", icon: "star.fill", tint: .bacanGreen, items: review.topFeatures)
        }
        if !review.underusedFeatures.isEmpty {
            labelSection("Quiet corners", icon: "moon.zzz.fill", tint: .sky, items: review.underusedFeatures)
        }
        if !review.frictionSignals.isEmpty {
            labelSection("Little snags", icon: "exclamationmark.triangle.fill", tint: .terracotta, items: review.frictionSignals)
        }

        if !review.suggestions.isEmpty {
            Section("Three ideas") {
                ForEach(review.suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.ink)
                        if !suggestion.why.isEmpty {
                            Text(suggestion.why)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var loadingContent: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.ink.opacity(0.12))
                        .frame(height: 14)
                        .frame(maxWidth: .infinity)
                }
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.ink.opacity(0.12))
                    .frame(width: 160, height: 14)
            }
            .padding(.vertical, 6)
            .redacted(reason: .placeholder)
            .shimmering()
            .accessibilityIdentifier("usage-review-shimmer")
        } header: {
            Text("Reading the tea leaves…")
        }
    }

    private func labelSection(_ title: String, icon: String, tint: Color, items: [String]) -> some View {
        Section(title) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(tint)
                    Text(item).foregroundStyle(Color.ink)
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func windowLabel(_ review: UsageReview) -> String {
        let events = review.eventCount == 1 ? "1 signal" : "\(review.eventCount) signals"
        return "Last \(review.windowDays) days · \(events)"
    }
}
