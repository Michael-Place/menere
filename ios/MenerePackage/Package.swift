// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MenerePackage",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "MenereUI", targets: ["MenereUI"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "AuthenticationDomain", targets: ["AuthenticationDomain"]),
        .library(name: "AuthenticationFeature", targets: ["AuthenticationFeature"]),
        .library(name: "OnboardingFeature", targets: ["OnboardingFeature"]),
        .library(name: "SettingsFeature", targets: ["SettingsFeature"]),
        .library(name: "UserDomain", targets: ["UserDomain"]),
        .library(name: "WineDomain", targets: ["WineDomain"]),
        .library(name: "FamilyDomain", targets: ["FamilyDomain"]),
        .library(name: "TodayFeature", targets: ["TodayFeature"]),
        .library(name: "ListsFeature", targets: ["ListsFeature"]),
        .library(name: "DocsFeature", targets: ["DocsFeature"]),
        .library(name: "CalendarFeature", targets: ["CalendarFeature"]),
        .library(name: "ChoresFeature", targets: ["ChoresFeature"]),
        .library(name: "RecipesFeature", targets: ["RecipesFeature"]),
        .library(name: "PersistenceClient", targets: ["PersistenceClient"]),
        .library(name: "StorageClient", targets: ["StorageClient"]),
        .library(name: "LocationClient", targets: ["LocationClient"]),
        .library(name: "HueClient", targets: ["HueClient"]),
        .library(name: "LutronClient", targets: ["LutronClient"]),
        .library(name: "SonosClient", targets: ["SonosClient"]),
        .library(name: "NestClient", targets: ["NestClient"]),
        .library(name: "HubspaceClient", targets: ["HubspaceClient"]),
        .library(name: "IdentifyClient", targets: ["IdentifyClient"]),
        .library(name: "EnrichmentClient", targets: ["EnrichmentClient"]),
        .library(name: "CatalogClient", targets: ["CatalogClient"]),
        .library(name: "HouseholdClient", targets: ["HouseholdClient"]),
        .library(name: "PushClient", targets: ["PushClient"]),
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
            name: "MenereUI"
        ),
        .target(
            name: "AppCore",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "MenereUI",
                "AuthenticationDomain",
                "AuthenticationFeature",
                "OnboardingFeature",
                "SettingsFeature",
                "UserDomain",
                "WineDomain",
                "FamilyDomain",
                "PersistenceClient",
                "StorageClient",
                "IdentifyClient",
                "ScanFeature",
                "CellarFeature",
                "TodayFeature",
                "ListsFeature",
                "DocsFeature",
                "CalendarFeature",
                "ChoresFeature",
                "RecipesFeature",
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
                "MenereUI",
                "AuthenticationDomain",
            ]
        ),
        .target(
            name: "OnboardingFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "MenereUI",
                "AuthenticationFeature",
                "UserDomain",
            ]
        ),
        .target(
            name: "SettingsFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "AuthenticationDomain",
                "UserDomain",
                "WineDomain",
                "FamilyDomain",
                "PersistenceClient",
                "HouseholdClient",
                "HueClient",
                "LutronClient",
                "NestClient",
                "HubspaceClient",
            ]
        ),
        .target(
            name: "TodayFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
                "DocsFeature",
                "LocationClient",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
            ]
        ),
        .target(
            name: "ListsFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
                "CellarFeature",
                "ScanFeature",
                "WineDomain",
                "DocsFeature",
            ]
        ),
        .target(
            name: "DocsFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "StorageClient",
                "UserDomain",
            ]
        ),
        .target(
            name: "CalendarFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
        .target(
            name: "ChoresFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "StorageClient",
                "UserDomain",
                "DocsFeature",
            ]
        ),
        .target(
            name: "RecipesFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
                "LocationClient",
            ]
        ),
        .target(
            name: "HouseholdClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
            ]
        ),
        .target(
            name: "PushClient",
            dependencies: [
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
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
            name: "FamilyDomain"
        ),
        .target(
            name: "PersistenceClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "WineDomain",
                "FamilyDomain",
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
            name: "LocationClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ]
        ),
        .target(
            name: "HueClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "LutronClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "SonosClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "NestClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "HubspaceClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "IdentifyClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
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
                "MenereUI",
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
                "MenereUI",
                "WineDomain",
                "JournalFeature",
                "UserDomain",
            ]
        ),
        .target(
            name: "JournalFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "WineDomain",
                "PersistenceClient",
                "StorageClient",
                "UserDomain",
            ]
        ),
        .target(
            name: "CellarFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "WineDomain",
                "PersistenceClient",
                "UserDomain",
                "BottleCardFeature",
                "JournalFeature",
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
            name: "IdentifyClientTests",
            dependencies: [
                "IdentifyClient",
                "WineDomain",
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
                "UserDomain",
            ]
        ),
        .testTarget(
            name: "SettingsFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "SettingsFeature",
                "WineDomain",
                "PersistenceClient",
                "HouseholdClient",
                "UserDomain",
                "HueClient",
                "LutronClient",
                "NestClient",
                "HubspaceClient",
                "FamilyDomain",
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
                "BottleCardFeature",
                "JournalFeature",
            ]
        ),
        .testTarget(
            name: "HueClientTests",
            dependencies: [
                "HueClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "LutronClientTests",
            dependencies: [
                "LutronClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "SonosClientTests",
            dependencies: [
                "SonosClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "NestClientTests",
            dependencies: [
                "NestClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "HubspaceClientTests",
            dependencies: [
                "HubspaceClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "TodayFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "TodayFeature",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "AppCore",
                "CellarFeature",
                "WineDomain",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
