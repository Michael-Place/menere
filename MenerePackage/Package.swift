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
        .library(name: "StorageClient", targets: ["StorageClient"]),
        .library(name: "IdentifyClient", targets: ["IdentifyClient"]),
        .library(name: "EnrichmentClient", targets: ["EnrichmentClient"]),
        .library(name: "CatalogClient", targets: ["CatalogClient"]),
        .library(name: "ScanFeature", targets: ["ScanFeature"]),
        .library(name: "BottleCardFeature", targets: ["BottleCardFeature"]),
        .library(name: "JournalFeature", targets: ["JournalFeature"]),
        .library(name: "CellarFeature", targets: ["CellarFeature"]),
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
                "StorageClient",
                "IdentifyClient",
                "ScanFeature",
                "CellarFeature",
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
                "WineDomain",
                "PersistenceClient",
                "UserDomain",
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
        .target(
            name: "StorageClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk"),
            ]
        ),
        .target(
            name: "IdentifyClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "WineDomain",
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "EnrichmentClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "WineDomain",
            ]
        ),
        .target(
            name: "CatalogClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "WineDomain",
                "PersistenceClient",
                "EnrichmentClient",
            ]
        ),
        .target(
            name: "ScanFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "IdentifyClient",
                "CatalogClient",
                "WineDomain",
                "BottleCardFeature",
            ]
        ),
        .target(
            name: "BottleCardFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "WineDomain",
                "JournalFeature",
                "UserDomain",
            ]
        ),
        .target(
            name: "JournalFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "WineDomain",
                "PersistenceClient",
                "StorageClient",
            ]
        ),
        .target(
            name: "CellarFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "WineDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
        .testTarget(
            name: "CatalogClientTests",
            dependencies: [
                "CatalogClient",
                "PersistenceClient",
                "EnrichmentClient",
                "WineDomain",
            ]
        ),
        .testTarget(
            name: "EnrichmentClientTests",
            dependencies: [
                "EnrichmentClient",
                "WineDomain",
            ]
        ),
        .testTarget(
            name: "BottleCardFeatureTests",
            dependencies: [
                "BottleCardFeature",
                "WineDomain",
                "JournalFeature",
                "UserDomain",
            ]
        ),
        .testTarget(
            name: "ScanFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ScanFeature",
                "IdentifyClient",
                "CatalogClient",
                "WineDomain",
            ]
        ),
        .testTarget(
            name: "JournalFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "JournalFeature",
                "WineDomain",
                "PersistenceClient",
                "StorageClient",
            ]
        ),
        .testTarget(
            name: "HomeFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "HomeFeature",
                "WineDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
        .testTarget(
            name: "CellarFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "CellarFeature",
                "WineDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
