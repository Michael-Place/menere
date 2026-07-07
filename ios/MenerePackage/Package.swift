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
        .library(name: "HouseFeature", targets: ["HouseFeature"]),
        .library(name: "TodayFeature", targets: ["TodayFeature"]),
        .library(name: "MemoriesFeature", targets: ["MemoriesFeature"]),
        .library(name: "ListsFeature", targets: ["ListsFeature"]),
        .library(name: "ProjectsFeature", targets: ["ProjectsFeature"]),
        .library(name: "DocsFeature", targets: ["DocsFeature"]),
        .library(name: "CalendarFeature", targets: ["CalendarFeature"]),
        .library(name: "CalendarSyncClient", targets: ["CalendarSyncClient"]),
        .library(name: "ChoresFeature", targets: ["ChoresFeature"]),
        .library(name: "RecipesFeature", targets: ["RecipesFeature"]),
        .library(name: "PersistenceClient", targets: ["PersistenceClient"]),
        .library(name: "LocalCache", targets: ["LocalCache"]),
        .library(name: "AnalyticsClient", targets: ["AnalyticsClient"]),
        .library(name: "StorageClient", targets: ["StorageClient"]),
        .library(name: "LocationClient", targets: ["LocationClient"]),
        .library(name: "PhotoCurationClient", targets: ["PhotoCurationClient"]),
        .library(name: "PhotoLibraryClient", targets: ["PhotoLibraryClient"]),
        .library(name: "HueClient", targets: ["HueClient"]),
        .library(name: "LutronClient", targets: ["LutronClient"]),
        .library(name: "SonosClient", targets: ["SonosClient"]),
        .library(name: "NestClient", targets: ["NestClient"]),
        .library(name: "HubspaceClient", targets: ["HubspaceClient"]),
        .library(name: "MerossClient", targets: ["MerossClient"]),
        .library(name: "HomeKitClient", targets: ["HomeKitClient"]),
        .library(name: "IdentifyClient", targets: ["IdentifyClient"]),
        .library(name: "EnrichmentClient", targets: ["EnrichmentClient"]),
        .library(name: "CatalogClient", targets: ["CatalogClient"]),
        .library(name: "HouseholdClient", targets: ["HouseholdClient"]),
        .library(name: "PushClient", targets: ["PushClient"]),
        .library(name: "ScanFeature", targets: ["ScanFeature"]),
        .library(name: "BottleCardFeature", targets: ["BottleCardFeature"]),
        .library(name: "JournalFeature", targets: ["JournalFeature"]),
        .library(name: "CellarFeature", targets: ["CellarFeature"]),
        .library(name: "MoneyFeature", targets: ["MoneyFeature"]),
        .library(name: "AgentTools", targets: ["AgentTools"]),
        .library(name: "AssistantFeature", targets: ["AssistantFeature"]),
        // V5 — Foundation-only bridge shared by the app + the Share Extension (app-group inbox).
        .library(name: "SharedCapture", targets: ["SharedCapture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk", .upToNextMajor(from: "11.13.0")),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", .upToNextMajor(from: "4.0.1")),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", .upToNextMajor(from: "1.19.0")),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.9.0"),
        .package(url: "https://github.com/pointfreeco/swift-sharing.git", from: "2.4.0"),
        // H2 — local SQLite mirror (offline-first, snappy). pointfree sqlite-data (aka SharingGRDB):
        // reactive @FetchAll reads over GRDB, integrated with swift-sharing (already a dep).
        .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.6.6"),
    ],
    targets: [
        .target(
            name: "MenereUI",
            dependencies: [
                // H1 image pipeline: BacanImage(path:) resolves the Storage loader via @Dependency(\.storage).
                // StorageClient does NOT depend on MenereUI, so this is acyclic.
                .product(name: "Dependencies", package: "swift-dependencies"),
                "StorageClient",
                // FL1: the in-app photo browser (PhotoLibraryBrowser) reads the library through this
                // client. PhotoLibraryClient does NOT depend on MenereUI, so this stays acyclic.
                "PhotoLibraryClient",
            ]
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
                "AnalyticsClient",
                "StorageClient",
                "IdentifyClient",
                "ScanFeature",
                "CellarFeature",
                "TodayFeature",
                "MemoriesFeature",
                "ListsFeature",
                "DocsFeature",
                "CalendarFeature",
                "ChoresFeature",
                "RecipesFeature",
                "AssistantFeature",
                "PhotoCurationClient",
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
                "AnalyticsClient",
                "HouseholdClient",
                "StorageClient",
                "PhotoCurationClient",
                "HueClient",
                "LutronClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
            ]
        ),
        // Shared smart-home control surface (the `HouseView`/`HouseReducer` control screen + the
        // reusable `HouseCardReducer` loader). Lives here so BOTH Today (glance card) and Home (hub
        // Smart-home card) can reach it without a target cycle.
        .target(
            name: "HouseFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
            ]
        ),
        .target(
            name: "TodayFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "HouseFeature",
                "CalendarFeature",
                "PersistenceClient",
                "AnalyticsClient",
                "UserDomain",
                "DocsFeature",
                "StorageClient",
                "LocationClient",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
                // V5 Share Extension last-mile: read the parked share (`CaptureHandoffStore.take()`)
                // and prefill the smart-capture surface with the shared URL/text/image.
                "SharedCapture",
            ]
        ),
        .target(
            name: "MemoriesFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "AnalyticsClient",
                "UserDomain",
                "StorageClient",
                // FL1: the memory editor loads full images for browser-picked assets via this client.
                "PhotoLibraryClient",
                // H2-ext: offline-first local SQLite mirror for the instant timeline paint.
                "LocalCache",
            ]
        ),
        .target(
            name: "ListsFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "AnalyticsClient",
                "UserDomain",
                "CellarFeature",
                "ScanFeature",
                "WineDomain",
                "DocsFeature",
                "MoneyFeature",
                // Projects PR1: the "Projects" pinned row pushes the ProjectsFeature workspace.
                "ProjectsFeature",
                // H2-ext: offline-first local SQLite mirror for the instant Lists paint.
                "LocalCache",
            ]
        ),
        // Projects PR1 — family initiative workspaces (the pool build, Oliver's school hunt). A
        // Projects list + a rich workspace (inspiration board, linked Brain docs, links, tasks,
        // notes). Reached from the Lists tab. `Document.projectIds` is the PR2 ingestion seam.
        .target(
            name: "ProjectsFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "StorageClient",
                "PhotoLibraryClient",
                "AnalyticsClient",
                "UserDomain",
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
                "AnalyticsClient",
                "UserDomain",
                // H2-ext: offline-first local SQLite mirror for the instant Family Brain paint.
                "LocalCache",
            ]
        ),
        .target(
            name: "CalendarFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "AnalyticsClient",
                "UserDomain",
                "CalendarSyncClient",
            ]
        ),
        .target(
            name: "CalendarSyncClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "ChoresFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "HouseFeature",
                "HueClient",
                "PersistenceClient",
                "LocalCache",
                "AnalyticsClient",
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
                "AnalyticsClient",
                "UserDomain",
                "LocationClient",
            ]
        ),
        .target(
            name: "HouseholdClient",
            dependencies: [
                "FamilyDomain",
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
        // H2 — the local SQLite mirror. Owns the on-disk DB (Application Support), the CareItemRecord
        // schema, write-through sync from Firestore, and a reactive @FetchAll-backed observation. Kept
        // dependency-light (FamilyDomain + SQLiteData) so features can read from it acyclically.
        .target(
            name: "LocalCache",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "SQLiteData", package: "sqlite-data"),
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
        // Private, family-only usage telemetry (P25 — the signal loop). Writes to the family's own
        // member-gated Firestore `households/{hid}/analytics`. No third-party analytics.
        .target(
            name: "AnalyticsClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                "FamilyDomain",
                "UserDomain",
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
            name: "PhotoCurationClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
            ]
        ),
        // FL1 — the read side of the PhotoKit door (browse/search the library into memories). Kept
        // dependency-light (no MenereUI) so MenereUI can depend on it acyclically.
        .target(
            name: "PhotoLibraryClient",
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
            name: "MerossClient",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                "FamilyDomain",
            ]
        ),
        .target(
            name: "HomeKitClient",
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
        .target(
            name: "MoneyFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "MenereUI",
                "FamilyDomain",
                "PersistenceClient",
                "AnalyticsClient",
                "UserDomain",
                "DocsFeature",
            ]
        ),
        .target(
            name: "AgentTools",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "FirebaseFunctions", package: "firebase-ios-sdk"),
                "FamilyDomain",
                "PersistenceClient",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
            ]
        ),
        .target(
            name: "AssistantFeature",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MenereUI",
                "AgentTools",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
        // V5 — the Share Extension ingestion bridge. Foundation-only (no Firebase/UI) so the
        // lightweight app-extension target can link it. Owns the app-group inbox + handoff store.
        .target(
            name: "SharedCapture"
        ),
        .testTarget(
            name: "AgentToolsTests",
            dependencies: [
                .product(name: "Dependencies", package: "swift-dependencies"),
                "AgentTools",
                "FamilyDomain",
                "PersistenceClient",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
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
            name: "PhotoCurationClientTests",
            dependencies: [
                "PhotoCurationClient",
            ]
        ),
        .testTarget(
            name: "PhotoLibraryClientTests",
            dependencies: [
                "PhotoLibraryClient",
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
                "AnalyticsClient",
                "HouseholdClient",
                "UserDomain",
                "HueClient",
                "LutronClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
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
            name: "MerossClientTests",
            dependencies: [
                "MerossClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "HomeKitClientTests",
            dependencies: [
                "HomeKitClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "HouseFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "HouseFeature",
                "HueClient",
                "LutronClient",
                "SonosClient",
                "NestClient",
                "HubspaceClient",
                "MerossClient",
                "HomeKitClient",
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
        .testTarget(
            name: "MoneyFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "MoneyFeature",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
        .testTarget(
            name: "ChoresFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "ChoresFeature",
                "FamilyDomain",
                "PersistenceClient",
                "StorageClient",
                "UserDomain",
            ]
        ),
        .testTarget(
            name: "CalendarSyncClientTests",
            dependencies: [
                "CalendarSyncClient",
                "FamilyDomain",
            ]
        ),
        .testTarget(
            name: "CalendarFeatureTests",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                "CalendarFeature",
                "CalendarSyncClient",
                "FamilyDomain",
                "PersistenceClient",
                "UserDomain",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
