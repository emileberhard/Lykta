import Foundation
import LyktaCore
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(NotificationRegistration.registered(PushToken(deviceToken)), subject: application)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(NotificationRegistration.failed(error.localizedDescription), subject: application)
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let tap = options.notificationResponse.flatMap(NotificationTap.init) {
            NotificationCenter.default.post(tap, subject: application)
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tap = NotificationTap(response) else { return }
        await MainActor.run { NotificationCenter.default.post(tap, subject: UIApplication.shared) }
    }
}

nonisolated struct NotificationTap: NotificationCenter.MainActorMessage, Sendable {
    typealias Subject = UIApplication

    let notification: UUID
    let link: URL

    init?(_ response: UNNotificationResponse) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let payload = NotificationPayload(userInfo: response.notification.request.content.userInfo), let link = payload.link else { return nil }
        notification = payload.id
        self.link = link
    }
}

enum NotificationRegistration: NotificationCenter.MainActorMessage {
    typealias Subject = UIApplication

    case registered(PushToken)
    case failed(String)
}
