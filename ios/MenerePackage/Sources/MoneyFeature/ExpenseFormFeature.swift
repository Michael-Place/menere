import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI

/// The manual quick-add sheet (P13 ingestion ladder, rung 2). Amount-keypad-first, then vendor,
/// category, date, notes. Emits the built `Expense` up via a delegate; the parent persists it.
@Reducer
public struct ExpenseFormReducer {
    @ObservableState
    public struct State: Equatable {
        var amountText: String
        var vendor: String
        var category: ExpenseCategory
        var date: Date
        var notes: String
        /// Defaulted to the current member so a quick-add is attributed without extra taps.
        var memberId: String?

        public init(
            amountText: String = "",
            vendor: String = "",
            category: ExpenseCategory = .other,
            date: Date = Date(),
            notes: String = "",
            memberId: String? = nil
        ) {
            self.amountText = amountText
            self.vendor = vendor
            self.category = category
            self.date = date
            self.notes = notes
            self.memberId = memberId
        }

        /// Parsed amount (nil when blank/garbage) — gates the Save button.
        var amount: Double? {
            let cleaned = amountText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            guard let value = Double(cleaned), value > 0 else { return nil }
            return value
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case cancelTapped
        case binding(BindingAction<State>)
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case save(Expense)
            case cancel
        }
    }

    public init() {}

    @Dependency(\.uuid) var uuid
    @Dependency(\.date) var date

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .saveTapped:
                guard let amount = state.amount else { return .none }
                let trimmedVendor = state.vendor.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedNotes = state.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                let expense = Expense(
                    id: uuid().uuidString,
                    amount: amount,
                    vendor: trimmedVendor.isEmpty ? nil : trimmedVendor,
                    category: state.category,
                    date: state.date,
                    memberId: state.memberId,
                    source: .manual,
                    documentId: nil,
                    notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                    createdAt: date.now
                )
                return .send(.delegate(.save(expense)))

            case .cancelTapped:
                return .send(.delegate(.cancel))

            case .binding, .delegate:
                return .none
            }
        }
    }
}

public struct ExpenseFormView: View {
    @Bindable var store: StoreOf<ExpenseFormReducer>
    @FocusState private var amountFocused: Bool

    public init(store: StoreOf<ExpenseFormReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 4) {
                        Text("$")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.inkSoft)
                        TextField("0", text: $store.amountText)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .accessibilityIdentifier("expense-amount-field")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color.familySurface)

                Section {
                    TextField("Where? (Green Thumb, Costco…)", text: $store.vendor)
                        .accessibilityIdentifier("expense-vendor-field")
                    Picker("Category", selection: $store.category) {
                        ForEach(ExpenseCategory.allCases, id: \.self) { category in
                            Label(category.displayName, systemImage: category.symbolName).tag(category)
                        }
                    }
                    DatePicker("Date", selection: $store.date, displayedComponents: .date)
                    TextField("Notes (optional)", text: $store.notes, axis: .vertical)
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Log an expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelTapped) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .disabled(store.amount == nil)
                        .accessibilityIdentifier("expense-save-button")
                }
            }
            .onAppear { amountFocused = true }
        }
    }
}
