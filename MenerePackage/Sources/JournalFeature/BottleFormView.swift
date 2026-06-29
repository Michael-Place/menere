import ComposableArchitecture
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
        public let uid: String

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

        public init(wine: Wine, uid: String) {
            self.wine = wine
            self.uid = uid
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
                    id: uuid().uuidString,
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
                    createdAt: now
                )
                state.isSaving = true
                state.errorMessage = nil
                return .run { [uid = state.uid] send in
                    do {
                        try await persistence.saveBottle(uid, bottle)
                        await send(.saveResponse(.success(bottle)))
                    } catch {
                        await send(.saveResponse(.failure(error.localizedDescription)))
                    }
                }

            case .saveResponse(.success(let bottle)):
                state.isSaving = false
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
                        .font(.headline)
                    if let name = store.wine.name {
                        Text(name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let vintage = store.wine.vintage {
                        Text(String(vintage))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
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
                        Text("Save to cellar")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isSaving)
                .accessibilityIdentifier("save-bottle-button")
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { store.send(.cancelTapped) }
                    .accessibilityIdentifier("cancel-bottle-button")
            }
        }
    }
}
