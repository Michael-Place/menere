import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// Edit the signed-in user's own family member profile: display name, color, and avatar.
@Reducer
public struct ProfileEditReducer {
    @ObservableState
    public struct State: Equatable {
        var member: HouseholdMember

        public init(member: HouseholdMember) {
            self.member = member
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case saved(HouseholdMember) }
    }

    public init() {}

    @Dependency(\.dismiss) var dismiss

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .saveTapped:
                guard let hid = hid(),
                      !state.member.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return .none }
                let member = state.member
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveMember(hid, member)
                    await send(.delegate(.saved(member)))
                    await dismiss()
                }

            case .delegate, .binding:
                return .none
            }
        }
    }
}

public struct ProfileEditView: View {
    @Bindable var store: StoreOf<ProfileEditReducer>
    private let columns = Array(repeating: GridItem(.flexible()), count: 4)

    public init(store: StoreOf<ProfileEditReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Your name", text: $store.member.name)
                        .accessibilityIdentifier("profile-name-field")
                }

                Section("Color") {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(MemberColor.allCases, id: \.self) { color in
                            let rgb = color.rgb
                            Circle()
                                .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle().stroke(Color.ink, lineWidth: store.member.color == color ? 3 : 0)
                                )
                                .onTapGesture { store.member.color = color }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Avatar") {
                    let rgb = store.member.color.rgb
                    let tint = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(HouseholdMember.avatarOptions, id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.title2)
                                .foregroundStyle(store.member.avatarSystemName == symbol ? tint : Color.inkSoft)
                                .frame(width: 40, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(store.member.avatarSystemName == symbol ? tint.opacity(0.15) : .clear)
                                )
                                .onTapGesture { store.member.avatarSystemName = symbol }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("My Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .accessibilityIdentifier("save-profile-button")
                }
            }
        }
    }
}
