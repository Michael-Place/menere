import AuthenticationDomain
import ComposableArchitecture
import SwiftUI

@Reducer
public struct CountryCodeSelectionReducer {
    @ObservableState
    public struct State: Equatable {
        let countryCodes: [CountryCode]

        init() {
            @Dependency(\.phoneNumberUtility) var phoneNumberUtility
            self.countryCodes = phoneNumberUtility.countryCodes()
        }
    }

    public enum Action: Equatable {
        case countryCodeSelected(CountryCode)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .countryCodeSelected:
                return .run { _ in
                    @Dependency(\.dismiss) var dismiss
                    await dismiss()
                }
            }
        }
    }
}

struct CountryCodeSelectionView: View {
    let store: StoreOf<CountryCodeSelectionReducer>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.countryCodes, id: \.self) { countryCode in
                    Button(action: { store.send(.countryCodeSelected(countryCode)) }) {
                        HStack {
                            Text(countryCode.flagUnicode)
                                .font(.system(size: 32))

                            VStack(alignment: .leading) {
                                Text(countryCode.countryName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("+\(countryCode.callingCode)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
