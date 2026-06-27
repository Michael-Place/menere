// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MenerePackage",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "AuthenticationDomain", targets: ["AuthenticationDomain"]),
        .library(name: "AuthenticationFeature", targets: ["AuthenticationFeature"]),
        .library(name: "OnboardingFeature", targets: ["OnboardingFeature"]),
        .library(name: "HomeFeature", targets: ["HomeFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "UserDomain", targets: ["UserDomain"]),
        .library(name: "WineDomain", targets: ["WineDomain"]),
        .library(name: "PersistenceClient", targets: ["PersistenceClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", .upToNextMajor(from: "11.13.0")),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", .upToNextMajor(from: "4.0.1")),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", .upToNextMajor(from: "1.19.0")),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing.git", from: "2.4.0"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "AuthenticationDomain",
                "AuthenticationFeature",
                "OnboardingFeature",
                "HomeFeature",
                "SettingsFeature",
                "UserDomain",
                "WineDomain",
                "PersistenceClient",
            ]
        ),
        .target(
            name: "AuthenticationDomain",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
                "UserDomain",
            ]
        ),
        .target(
            name: "AuthenticationFeature",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "AuthenticationDomain",
            ]
        ),
        .target(
            name: "OnboardingFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "AuthenticationFeature",
                "UserDomain",
            ]
        ),
        .target(
            name: "HomeFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .target(
            name: "SettingsFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "AuthenticationDomain",
                "UserDomain",
            ]
        ),
        .target(
            name: "UserDomain",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
            ]
        ),
        .target(
            name: "WineDomain"
        ),
        .target(
            name: "PersistenceClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "WineDomain",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
