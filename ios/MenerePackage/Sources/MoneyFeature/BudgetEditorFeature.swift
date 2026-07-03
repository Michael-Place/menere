import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI

/// The in-Money budgets editor (P13 §5). Per-category optional monthly limits → a `BudgetConfig`.
/// This is the only settings-ish surface in Money; the Settings tab stays untouched.
@Reducer
public struct BudgetEditorReducer {
    @ObservableState
    public struct State: Equatable {
        /// `ExpenseCategory.rawValue` → the text field's current string ("" = no limit).
        var limitTexts: [String: String]
        /// Carried through untouched so saving budgets never clobbers the inbox dismissals.
        var dismissedDocumentIds: [String]

        public init(config: BudgetConfig) {
            var texts: [String: String] = [:]
            for category in ExpenseCategory.allCases {
                if let limit = config.limit(for: category) {
                    texts[category.rawValue] = Self.format(limit)
                } else {
                    texts[category.rawValue] = ""
                }
            }
            self.limitTexts = texts
            self.dismissedDocumentIds = config.dismissedDocumentIds
        }

        static func format(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }

        /// Rebuild a `BudgetConfig` from the current fields (blank / non-positive → dropped).
        func build() -> BudgetConfig {
            var limits: [String: Double] = [:]
            for (key, text) in limitTexts {
                let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
                if let value = Double(cleaned), value > 0 { limits[key] = value }
            }
            return BudgetConfig(limits: limits, dismissedDocumentIds: dismissedDocumentIds)
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case cancelTapped
        case binding(BindingAction<State>)
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case save(BudgetConfig)
            case cancel
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .saveTapped:
                return .send(.delegate(.save(state.build())))
            case .cancelTapped:
                return .send(.delegate(.cancel))
            case .binding, .delegate:
                return .none
            }
        }
    }
}

public struct BudgetEditorView: View {
    @Bindable var store: StoreOf<BudgetEditorReducer>

    public init(store: StoreOf<BudgetEditorReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Set a gentle monthly ceiling per category. Blank means no limit — no shame, just a heads-up when you sail past.")
                        .font(.callout)
                        .foregroundStyle(Color.inkSoft)
                }
                .listRowBackground(Color.familySurface)

                Section("Monthly limits") {
                    ForEach(ExpenseCategory.allCases, id: \.self) { category in
                        HStack {
                            Label {
                                Text(category.displayName).foregroundStyle(Color.ink)
                            } icon: {
                                Image(systemName: category.symbolName).foregroundStyle(Color.bacanGreen)
                            }
                            Spacer()
                            Text("$").foregroundStyle(Color.inkSoft)
                            TextField(
                                "—",
                                text: Binding(
                                    get: { store.limitTexts[category.rawValue] ?? "" },
                                    set: { store.limitTexts[category.rawValue] = $0 }
                                )
                            )
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .accessibilityIdentifier("budget-field-\(category.rawValue)")
                        }
                    }
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Budgets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelTapped) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("budget-save-button")
                }
            }
        }
    }
}
