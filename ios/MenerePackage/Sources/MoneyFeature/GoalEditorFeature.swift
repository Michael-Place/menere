import ComposableArchitecture
import FamilyDomain
import Foundation
import MenereUI
import SwiftUI

/// Add / edit a savings goal (Act V V4 — Money). One sheet handles it all: a new jar, editing the
/// target/deadline/plan, and *contributing* (bumping "Saved so far"). Emits the built `SavingsGoal`
/// up via a delegate; the parent persists it.
@Reducer
public struct GoalEditorReducer {
    @ObservableState
    public struct State: Equatable {
        /// The goal id being edited (stable across saves); a fresh uuid for a new goal.
        var id: String
        var isNew: Bool
        var name: String
        var targetText: String
        var savedText: String
        var contributeText: String
        var hasDeadline: Bool
        var targetDate: Date
        var hasPlan: Bool
        var monthlyText: String
        var symbol: String
        var createdAt: Date
        var now: Date

        /// New goal.
        public init(now: Date = Date()) {
            @Dependency(\.uuid) var uuid
            self.id = uuid().uuidString
            self.isNew = true
            self.name = ""
            self.targetText = ""
            self.savedText = ""
            self.contributeText = ""
            self.hasDeadline = false
            self.targetDate = Calendar.current.date(byAdding: .month, value: 6, to: now) ?? now
            self.hasPlan = false
            self.monthlyText = ""
            self.symbol = SavingsGoal.symbolChoices.first ?? "banknote.fill"
            self.createdAt = now
            self.now = now
        }

        /// Edit an existing goal.
        public init(goal: SavingsGoal, now: Date = Date()) {
            self.id = goal.id
            self.isNew = false
            self.name = goal.name
            self.targetText = Self.format(goal.targetAmount)
            self.savedText = Self.format(goal.savedAmount)
            self.contributeText = ""
            self.hasDeadline = goal.targetDate != nil
            self.targetDate = goal.targetDate ?? (Calendar.current.date(byAdding: .month, value: 6, to: now) ?? now)
            self.hasPlan = (goal.monthlyContribution ?? 0) > 0
            self.monthlyText = goal.monthlyContribution.map(Self.format) ?? ""
            self.symbol = goal.symbol ?? SavingsGoal.symbolChoices.first ?? "banknote.fill"
            self.createdAt = goal.createdAt
            self.now = now
        }

        static func format(_ value: Double) -> String {
            value == value.rounded() ? String(Int(value)) : String(value)
        }

        static func parse(_ text: String) -> Double? {
            let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
            guard let v = Double(cleaned), v > 0 else { return nil }
            return v
        }

        var target: Double? { Self.parse(targetText) }
        /// The saved-so-far figure, folding in any pending "contribute" amount.
        var savedTotal: Double {
            (Self.parse(savedText) ?? 0) + (Self.parse(contributeText) ?? 0)
        }
        var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && target != nil }

        func build() -> SavingsGoal {
            SavingsGoal(
                id: id,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                targetAmount: target ?? 0,
                savedAmount: savedTotal,
                targetDate: hasDeadline ? targetDate : nil,
                monthlyContribution: hasPlan ? Self.parse(monthlyText) : nil,
                symbol: symbol,
                createdAt: createdAt
            )
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case cancelTapped
        case deleteTapped
        case binding(BindingAction<State>)
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case save(SavingsGoal)
            case delete(String)
            case cancel
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .saveTapped:
                guard state.canSave else { return .none }
                return .send(.delegate(.save(state.build())))
            case .cancelTapped:
                return .send(.delegate(.cancel))
            case .deleteTapped:
                return .send(.delegate(.delete(state.id)))
            case .binding, .delegate:
                return .none
            }
        }
    }
}

public extension SavingsGoal {
    /// A tiny set of playful symbols for the goal-icon picker (kept in the UI-adjacent layer).
    static let symbolChoices = [
        "banknote.fill", "airplane", "house.fill", "car.fill", "gift.fill",
        "graduationcap.fill", "beach.umbrella.fill", "party.popper.fill", "cross.case.fill", "figure.and.child.holdinghands",
    ]
}

public struct GoalEditorView: View {
    @Bindable var store: StoreOf<GoalEditorReducer>

    public init(store: StoreOf<GoalEditorReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What are you saving for?", text: $store.name)
                        .accessibilityIdentifier("goal-name-field")
                    HStack {
                        Text("Target").foregroundStyle(Color.ink)
                        Spacer()
                        Text("$").foregroundStyle(Color.inkSoft)
                        TextField("0", text: $store.targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityIdentifier("goal-target-field")
                    }
                    HStack {
                        Text("Saved so far").foregroundStyle(Color.ink)
                        Spacer()
                        Text("$").foregroundStyle(Color.inkSoft)
                        TextField("0", text: $store.savedText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityIdentifier("goal-saved-field")
                    }
                }
                .listRowBackground(Color.familySurface)

                Section {
                    HStack {
                        Label("Add to the jar", systemImage: "plus.circle.fill")
                            .foregroundStyle(Color.bacanGreen)
                        Spacer()
                        Text("$").foregroundStyle(Color.inkSoft)
                        TextField("0", text: $store.contributeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityIdentifier("goal-contribute-field")
                    }
                } footer: {
                    Text("Drop a contribution in — it adds to what's already saved when you tap Save.")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                .listRowBackground(Color.familySurface)

                Section {
                    Toggle("Aim for a date", isOn: $store.hasDeadline)
                        .tint(Color.bacanGreen)
                        .accessibilityIdentifier("goal-deadline-toggle")
                    if store.hasDeadline {
                        DatePicker("By", selection: $store.targetDate, displayedComponents: .date)
                    }
                    Toggle("Plan a monthly set-aside", isOn: $store.hasPlan)
                        .tint(Color.bacanGreen)
                        .accessibilityIdentifier("goal-plan-toggle")
                    if store.hasPlan {
                        HStack {
                            Text("Each month").foregroundStyle(Color.ink)
                            Spacer()
                            Text("$").foregroundStyle(Color.inkSoft)
                            TextField("0", text: $store.monthlyText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                                .accessibilityIdentifier("goal-monthly-field")
                        }
                    }
                }
                .listRowBackground(Color.familySurface)

                Section("Icon") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(SavingsGoal.symbolChoices, id: \.self) { sym in
                                Button { store.symbol = sym } label: {
                                    Image(systemName: sym)
                                        .font(.title3)
                                        .frame(width: 44, height: 44)
                                        .foregroundStyle(store.symbol == sym ? Color.white : Color.bacanGreen)
                                        .background(
                                            Circle().fill(store.symbol == sym ? Color.bacanGreen : Color.bacanGreen.opacity(0.14))
                                        )
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listRowBackground(Color.familySurface)

                if !store.isNew {
                    Section {
                        Button(role: .destructive) { store.send(.deleteTapped) } label: {
                            Label("Delete goal", systemImage: "trash")
                        }
                        .accessibilityIdentifier("goal-delete-button")
                    }
                    .listRowBackground(Color.familySurface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle(store.isNew ? "New goal" : "Edit goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelTapped) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .disabled(!store.canSave)
                        .accessibilityIdentifier("goal-save-button")
                }
            }
        }
    }
}
