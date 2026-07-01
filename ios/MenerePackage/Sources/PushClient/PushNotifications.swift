import FirebaseAuth
import FirebaseFirestore
import FirebaseMessaging
import UIKit
import UserNotifications

/// Firebase Cloud Messaging setup for the app. Requests notification permission, registers for
/// remote notifications, and persists the FCM registration token to `users/{uid}.fcmToken` so the
/// notify-only Cloud Function triggers can reach this device. Self-contained so the App target's
/// `AppDelegate` only needs to call `start(application:)` and forward the APNs token.
public final class PushNotifications: NSObject, MessagingDelegate, UNUserNotificationCenterDelegate {
    public static let shared = PushNotifications()

    private var authListener: AuthStateDidChangeListenerHandle?

    override private init() { super.init() }

    /// Wire up messaging + notification delegates and request authorization. Safe to call once at
    /// launch (before or after sign-in) — the token is (re)saved whenever a user is signed in.
    public func start(application: UIApplication) {
        Messaging.messaging().delegate = self
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { application.registerForRemoteNotifications() }
        }
        // Re-persist the token on sign-in (the first token callback may arrive before auth).
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard user != nil else { return }
            self?.saveCurrentToken()
        }
    }

    /// Forward the APNs device token to FCM (call from `didRegisterForRemoteNotifications`).
    public func setAPNSToken(_ deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    private func saveCurrentToken() {
        Messaging.messaging().token { token, _ in
            guard let token, let uid = Auth.auth().currentUser?.uid else { return }
            Firestore.firestore().collection("users").document(uid).setData(["fcmToken": token], merge: true)
        }
    }

    // MARK: MessagingDelegate

    public func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken, let uid = Auth.auth().currentUser?.uid else { return }
        Firestore.firestore().collection("users").document(uid).setData(["fcmToken": fcmToken], merge: true)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show notifications as a banner even when the app is in the foreground.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
