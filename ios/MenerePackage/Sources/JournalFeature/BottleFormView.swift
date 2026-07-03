import ComposableArchitecture
import MenereUI
import PersistenceClient
import SwiftUI
import WineDomain

/// "Add to cellar" form. Pure & uid-injected: the reducer never reads `@Shared(.user)` — the
/// integration layer passes the signed-in `uid` and the resolved `Wine` in at init, which keeps it
/// trivially testable. Persists a `Bottle` via `\.persistence` and reports the result upward via
/// `delegate`.
@Reducer
public struct BottleFormReducer {
    @ObservableState
    public struct State: Equatable {
        public let wine: Wine
        public let hid: String

        var priceText: String = ""
        var currency: String = "USD"
        var quantity: Int = 1
        var store: String = ""
        var storageLocation: String = ""
        var purchaseDate: Date = Date()
        var includePurchaseDate: Bool = true
        var drinkFromText: String = ""
        var drinkByText: String = ""
        var status: BottleStatus = .cellared
        var isSaving: Bool = false
        var errorMessage: String?
        /// Transient trigger bumped on each successful save, just before `.delegate(.saved)`. The view
        /// observes it via `.successHaptic(_:)` so a save celebration fires even as the form dismisses.
        var savedTick = 0

        /// Non-nil in edit mode: the id of the bottle being edited (save reuses it instead of minting).
        public var editingID: String? = nil
        /// The original `createdAt` of the bottle being edited, preserved across saves.
        var originalCreatedAt: Date? = nil

        public init(wine: Wine, hid: String) {
            self.wine = wine
            self.hid = hid
        }

        /// Edit mode: prefill every field from an existing `Bottle`. Save reuses `editingID` +
        /// `originalCreatedAt` so the id and creation timestamp survive the round-trip.
        public init(editing bottle: Bottle, wine: Wine, hid: String) {
            self.wine = wine
            self.hid = hid
            self.priceText = bottle.price.map { price in
                price == price.rounded() ? String(Int(price)) : String(price)
            } ?? ""
            self.currency = bottle.currency ?? "USD"
            self.quantity = bottle.quantity
            self.store = bottle.store ?? ""
            self.storageLocation = bottle.storageLocation ?? ""
            if let purchaseDate = bottle.purchaseDate {
                self.purchaseDate = purchaseDate
                self.includePurchaseDate = true
            } else {
                self.includePurchaseDate = false
            }
            self.drinkFromText = bottle.drinkFrom.map(String.init) ?? ""
            self.drinkByText = bottle.drinkBy.map(String.init) ?? ""
            self.status = bottle.status
            self.editingID = bottle.id
            self.originalCreatedAt = bottle.createdAt
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case saveResponse(SaveResult)
        case cancelTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum SaveResult: Equatable {
            case success(Bottle)
            case failure(String)
        }

        public enum Delegate: Equatable {
            case saved(Bottle)
            case cancelled
        }
    }

    @Dependency(\.persistence) var persistence
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .saveTapped:
                guard !state.isSaving else { return .none }
                let bottle = Bottle(
                    id: state.editingID ?? uuid().uuidString,
                    wineId: state.wine.id,
                    purchaseDate: state.includePurchaseDate ? state.purchaseDate : nil,
                    price: Double(state.priceText.trimmingCharacters(in: .whitespaces)),
                    currency: state.currency.isEmpty ? nil : state.currency,
                    quantity: state.quantity,
                    store: state.store.isEmpty ? nil : state.store,
                    storageLocation: state.storageLocation.isEmpty ? nil : state.storageLocation,
                    drinkFrom: Int(state.drinkFromText.trimmingCharacters(in: .whitespaces)),
                    drinkBy: Int(state.drinkByText.trimmingCharacters(in: .whitespaces)),
                    status: state.status,
                    createdAt: state.originalCreatedAt ?? now
                )
                state.isSaving = true
                state.errorMessage = nil
                return .run { [hid = state.hid] send in
                    do {
                        try await persistence.saveBottle(hid, bottle)
                        await send(.saveResponse(.success(bottle)))
                    } catch {
                        await send(.saveResponse(.failure(error.localizedDescription)))
                    }
                }

            case .saveResponse(.success(let bottle)):
                state.isSaving = false
                state.savedTick += 1
                return .send(.delegate(.saved(bottle)))

            case .saveResponse(.failure(let message)):
                state.isSaving = false
                state.errorMessage = message
                return .none

            case .cancelTapped:
                return .send(.delegate(.cancelled))

            case .delegate, .binding:
                return .none
            }
        }
    }
}

public struct BottleFormView: View {
    @Bindable var store: StoreOf<BottleFormReducer>

    public init(store: StoreOf<BottleFormReducer>) {
        self.store = store
    }

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.wine.producer)
                        .wineName(.headline)
                        .foregroundStyle(Color.ink)
                    if let name = store.wine.name {
                        Text(name)
                            .cuvee()
                    }
                    if let vintage = store.wine.vintage {
                        Text(String(vintage))
                            .font(.subheadline)
                            .foregroundStyle(Color.inkSoft)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Purchase") {
                TextField("Price", text: $store.priceText)
                    .keyboardType(.decimalPad)
                    .accessibilityIdentifier("price-field")
                TextField("Currency", text: $store.currency)
                    .accessibilityIdentifier("currency-field")
                Stepper("Quantity: \(store.quantity)", value: $store.quantity, in: 1...999)
                    .accessibilityIdentifier("quantity-stepper")
                TextField("Store", text: $store.store)
                    .accessibilityIdentifier("store-field")
                Toggle("Record purchase date", isOn: $store.includePurchaseDate)
                if store.includePurchaseDate {
                    DatePicker(
                        "Purchase date",
                        selection: $store.purchaseDate,
                        displayedComponents: .date
                    )
                }
            }

            Section("Cellar") {
                TextField("Storage location", text: $store.storageLocation)
                    .accessibilityIdentifier("storage-location-field")
                TextField("Drink from (year)", text: $store.drinkFromText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("drink-from-field")
                TextField("Drink by (year)", text: $store.drinkByText)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("drink-by-field")
                Picker("Status", selection: $store.status) {
                    ForEach(BottleStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.capitalized).tag(status)
                    }
                }
                .accessibilityIdentifier("status-picker")
            }

            if let error = store.errorMessage {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button(action: { store.send(.saveTapped) }) {
                    if store.isSaving {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(store.editingID == nil ? "Save to cellar" : "Save changes")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isSaving)
                .accessibilityIdentifier("save-bottle-button")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.parchment)
        .successHaptic(store.savedTick)
        .wineNavTitle(store.editingID == nil ? "Add to cellar" : "Edit bottle")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { store.send(.cancelTapped) }
                    .accessibilityIdentifier("cancel-bottle-button")
            }
        }
        // Wine-stack screen: keep the parchment "Cellar & Candlelight" chrome.
        .wineChrome()
    }
}
