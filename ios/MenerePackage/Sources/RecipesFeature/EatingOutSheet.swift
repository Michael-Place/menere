import ComposableArchitecture
import Contacts
import Dependencies
import FamilyDomain
import LocationClient
import MapKit
import MenereUI
import SwiftUI

/// The "Eating out…" place-search sheet. Type a restaurant → live `MKLocalSearchCompleter`
/// suggestions (region-biased to the family's location when granted) → tap one to resolve its
/// address + coordinates via `MKLocalSearch`, or "use as-is" for a name-only night. An optional
/// reservation time rides along. All Apple first-party; no third-party APIs.
struct EatingOutSheet: View {
    @Bindable var store: StoreOf<RecipesReducer>

    @StateObject private var completer = PlaceCompleter()
    @FocusState private var searchFocused: Bool
    @Dependency(\.location) private var location

    private var draft: RecipesReducer.EatingOutDraft { store.eatingOutDraft }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                if draft.isPlaceSelected {
                    selectedSection
                    reservationSection
                } else {
                    suggestionsSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Eating out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.eatingOutDismissed) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveEatingOut) }
                        .disabled(!draft.isPlaceSelected)
                        .accessibilityIdentifier("eating-out-save")
                }
            }
        }
        .task {
            // Ask once; bias suggestions + enable Today's drive times when granted.
            location.requestWhenInUseAuthorization()
            if let here = await location.currentLocation() {
                completer.setRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
                ))
            }
            completer.update(draft.query)
            try? await Task.sleep(for: .milliseconds(350))
            searchFocused = true
        }
    }

    // MARK: Search field

    private var searchSection: some View {
        Section {
            TextField("La Cocina Mexican Kitchen", text: $store.eatingOutDraft.query)
                .focused($searchFocused)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("eating-out-search-field")
                .onChange(of: store.eatingOutDraft.query) { _, newValue in
                    // Editing after a place was chosen re-opens the search.
                    if draft.isPlaceSelected, newValue != draft.name {
                        store.send(.changePlaceTapped)
                    }
                    completer.update(newValue)
                }
        } footer: {
            if !draft.isPlaceSelected {
                Text("We'll grab the address and (later) the drive time — like a real calendar event.")
            }
        }
    }

    // MARK: Live suggestions

    @ViewBuilder
    private var suggestionsSection: some View {
        if !completer.results.isEmpty {
            Section("Places nearby") {
                ForEach(completer.results.indices, id: \.self) { i in
                    let result = completer.results[i]
                    Button {
                        resolve(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.title).foregroundStyle(Color.ink)
                            if !result.subtitle.isEmpty {
                                Text(result.subtitle).font(.caption).foregroundStyle(Color.inkSoft)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("eating-out-suggestion-\(i)")
                }
            }
        }

        let typed = draft.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            Section {
                Button {
                    store.send(.useTypedAsIs)
                } label: {
                    Label("Use \u{201C}\(typed)\u{201D} as-is", systemImage: "text.cursor")
                        .foregroundStyle(Color.bacanGreen)
                }
                .accessibilityIdentifier("eating-out-use-as-is")
            }
        }
    }

    // MARK: Chosen place

    private var selectedSection: some View {
        Section("Where to") {
            HStack(spacing: 12) {
                Image(systemName: draft.hasCoordinates ? "mappin.circle.fill" : "fork.knife.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.marigold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name ?? "").foregroundStyle(Color.ink)
                    if let address = draft.address, !address.isEmpty {
                        Text(address).font(.caption).foregroundStyle(Color.inkSoft)
                    } else {
                        Text("Name only — no map").font(.caption).foregroundStyle(Color.inkSoft)
                    }
                }
            }
            Button {
                store.send(.changePlaceTapped)
                searchFocused = true
            } label: {
                Label("Choose a different place", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.bacanGreen)
            }
            .accessibilityIdentifier("eating-out-change-place")
        }
    }

    private var reservationSection: some View {
        Section {
            Toggle("Reservation time", isOn: $store.eatingOutDraft.reservationEnabled)
                .accessibilityIdentifier("eating-out-reservation-toggle")
            if draft.reservationEnabled {
                DatePicker(
                    "Time",
                    selection: $store.eatingOutDraft.reservationTime,
                    displayedComponents: .hourAndMinute
                )
                .accessibilityIdentifier("eating-out-reservation-time")
            }
        } footer: {
            if draft.reservationEnabled {
                Text("We'll show when to leave on Today, and you can drop it on the calendar.")
            }
        }
    }

    // MARK: Resolve

    /// Resolve a completer suggestion to a concrete place (address + coordinates) off the main
    /// thread, then hand plain values back to the store. `MKLocalSearchCompletion` isn't Sendable,
    /// so resolution stays here in the view.
    private func resolve(_ completion: MKLocalSearchCompletion) {
        searchFocused = false
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            let search = MKLocalSearch(request: request)
            guard let response = try? await search.start(), let item = response.mapItems.first else {
                // Resolution failed — fall back to the suggestion text as a name-only place.
                store.send(.placeResolved(
                    name: completion.title, address: completion.subtitle, latitude: 0, longitude: 0
                ))
                store.send(.changePlaceTapped)
                store.send(.useTypedAsIs)
                return
            }
            let coord = item.placemark.coordinate
            let name = item.name ?? completion.title
            let address = Self.formatAddress(item.placemark) ?? completion.subtitle
            store.send(.placeResolved(
                name: name, address: address,
                latitude: coord.latitude, longitude: coord.longitude
            ))
        }
    }

    /// A one-line street address from a placemark, or nil.
    private static func formatAddress(_ placemark: MKPlacemark) -> String? {
        if let postal = placemark.postalAddress {
            let formatter = CNPostalAddressFormatter()
            let full = formatter.string(from: postal)
                .replacingOccurrences(of: "\n", with: ", ")
            if !full.isEmpty { return full }
        }
        return placemark.title
    }
}

/// Wraps `MKLocalSearchCompleter` as an `ObservableObject` so SwiftUI re-renders as live
/// point-of-interest suggestions stream in. Results render in-process (tappable in UI automation).
final class PlaceCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = .pointOfInterest
    }

    func setRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }

    func update(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        results = []
    }
}
