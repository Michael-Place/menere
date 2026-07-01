import Dependencies
import DependenciesMacros
import PhoneNumberKit

public struct CountryCode: Equatable, Hashable {
    public let countryName: String
    public let callingCode: String
    public let flagUnicode: String
}

public extension CountryCode {
    static let unitedStates = CountryCode(
        countryName: "United States",
        callingCode: "1",
        flagUnicode: "\u{1F1FA}\u{1F1F8}"
    )
}

@DependencyClient
public struct PhoneNumberUtility {
    public var deviceCountryCode: () -> CountryCode = { .unitedStates }
    public var countryCodes: () -> [CountryCode] = { [] }
}

extension PhoneNumberUtility: DependencyKey {
    public static var liveValue: PhoneNumberUtility {
        return PhoneNumberUtility(
            deviceCountryCode: {
                let phoneNumberKit = PhoneNumberKit.PhoneNumberUtility()
                let regionCode = PhoneNumberKit.PhoneNumberUtility.defaultRegionCode()
                @Dependency(\.locale) var locale

                guard
                    let callingCode = phoneNumberKit.countryCode(for: regionCode),
                    let countryName = locale.localizedString(forRegionCode: regionCode)
                else { return .unitedStates }

                return CountryCode(
                    countryName: countryName,
                    callingCode: String(callingCode),
                    flagUnicode: flag(from: regionCode)
                )
            },
            countryCodes: {
                let phoneNumberKit = PhoneNumberKit.PhoneNumberUtility()

                let codes: [CountryCode] = phoneNumberKit.allCountries().compactMap { country in
                    @Dependency(\.locale) var locale

                    guard
                        let callingCode = phoneNumberKit.countryCode(for: country),
                        let countryName = locale.localizedString(forRegionCode: country)
                    else { return nil }

                    return CountryCode(
                        countryName: countryName,
                        callingCode: String(callingCode),
                        flagUnicode: flag(from: country)
                    )
                }

                return Array(Set(codes))
                    .sorted { $0.callingCode < $1.callingCode }
            }
        )
    }

    static func flag(from countryCode: String) -> String {
        let base: UInt32 = 127397
        var flag = ""
        for scalar in countryCode.unicodeScalars {
            if let scalarValue = UnicodeScalar(base + scalar.value) {
                flag.unicodeScalars.append(scalarValue)
            }
        }
        return flag
    }
}

public extension DependencyValues {
    var phoneNumberUtility: PhoneNumberUtility {
        get { self[PhoneNumberUtility.self] }
        set { self[PhoneNumberUtility.self] = newValue }
    }
}
