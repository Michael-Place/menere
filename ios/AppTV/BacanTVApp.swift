import FirebaseCore
import FirebaseFirestore
import SwiftUI

/// The living-room ¡Bacán! Apple TV app (P27-T2-C1).
///
/// This first phase is deliberately lean: it proves the shared Firebase backend + a
/// **device-pairing** sign-in works on tvOS. On launch it either restores an existing TV session
/// or shows a big pairing code; once a family member confirms the code on their phone, the TV
/// signs in with a Firebase custom token and shows live household counts.
@main
struct BacanTVApp: App {
    init() {
        FirebaseApp.configure()
        // Pin explicit offline persistence (on by default) so the living-room screen keeps
        // rendering from cache if the network blips.
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
