import AppCore
import ComposableArchitecture
import FirebaseAuth
import Firebase
import FirebaseFirestore
import PushClient
import SharedCapture
import SwiftUI
import UIKit

@main
struct MenereApplication: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var store: StoreOf<AppReducer> {
        delegate.store
    }

    var body: some Scene {
        WindowGroup {
            AppView(store: store)
                .task {
                    // V5 Share Extension: drain anything the share sheet parked while we were away,
                    // BEFORE the tab shell first appears (so its onAppear consume finds `.capture`).
                    ShareIngestion.drainPendingShares()
                    await store.send(.task).finish()
                }
                .onChange(of: scenePhase) { _, scenePhase in
                    // V5 — on every foreground, pick up newly shared items and open capture.
                    if scenePhase == .active {
                        ShareIngestion.drainPendingShares()
                    }
                    store.send(.scenePhaseChanged(scenePhase))
                }
        }
    }
}

// MARK: - Share Extension pickup (V5 ingestion front door)

/// Drains the app-group inbox the Share Extension writes to, then routes the newest shared item to
/// the EXISTING smart-capture surface via `AppCore.IntentRouter` (`.capture`) — the same mechanism
/// V5-Siri's "Quick Capture" intent uses, so no change to `AppCore`/`TodayFeature` is required.
///
/// Handoff contract: the routed `PendingShare` is parked in `CaptureHandoffStore` (app-group
/// UserDefaults). The capture surface reads it via `CaptureHandoffStore.take()` to prefill the
/// compose field / photo, then clears it. Here we only clear the inbox *descriptors* (per the
/// pickup contract) and set the router destination.
enum ShareIngestion {
    static func drainPendingShares() {
        let shares = PendingShareStore.pending()
        guard let newest = shares.last else { return }

        // Park the newest share for the capture surface to consume once it opens.
        CaptureHandoffStore.stash(newest)

        // Clear the inbox descriptors; keep only the newest share's attachment (the handoff needs it),
        // pruning any orphaned attachment bytes from older/other shares.
        for share in shares {
            PendingShareStore.remove(share, keepAttachment: share.id == newest.id)
        }
        PendingShareStore.pruneAttachments(keeping: Set([newest.attachmentFilename].compactMap { $0 }))

        // Open the capture surface. `IntentRouter` persists until MainTabView drains it on
        // appear/foreground, so this survives a cold launch before the shell is on screen.
        IntentRouter.shared.pending = .capture
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate {
    lazy var store: StoreOf<AppReducer> = {
        Store(initialState: .init()) {
            AppReducer()
        }
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()

        // Make Firestore offline persistence explicit (it's on by default, but pin it so cellar /
        // home / scan reads serve from the local cache when the device is offline). Must be set
        // before any Firestore access.
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings()
        Firestore.firestore().settings = settings

        #if DEBUG
        // Let Firebase phone-auth *test numbers* work on the Simulator, where there is no APNs
        // and no reCAPTCHA client configured. Never enabled in release builds.
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
        #endif

        // Register for FCM push (notify-only family alerts). Persists the token to
        // users/{uid}.fcmToken; the notify-only Cloud Function triggers read it.
        PushNotifications.shared.start(application: application)
        return true
    }

    // Handle device token registration for phone auth + FCM
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
        PushNotifications.shared.setAPNSToken(deviceToken)
    }

    // Handle remote notification for phone auth verification
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if Auth.auth().canHandleNotification(userInfo) {
            completionHandler(.noData)
            return
        }
        completionHandler(.newData)
    }
}

// Enable swipe-back gesture even with custom navigation bar
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return viewControllers.count > 1
    }
}
