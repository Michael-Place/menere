import AppCore
import ComposableArchitecture
import FirebaseAuth
import Firebase
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
                .task { await store.send(.task).finish() }
                .onChange(of: scenePhase) { _, scenePhase in
                    store.send(.scenePhaseChanged(scenePhase))
                }
        }
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
        #if DEBUG
        // Let Firebase phone-auth *test numbers* work on the Simulator, where there is no APNs
        // and no reCAPTCHA client configured. Never enabled in release builds.
        Auth.auth().settings?.isAppVerificationDisabledForTesting = true
        #endif
        return true
    }

    // Handle device token registration for phone auth
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Auth.auth().setAPNSToken(deviceToken, type: .unknown)
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
