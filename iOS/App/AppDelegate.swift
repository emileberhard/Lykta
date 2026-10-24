import Foundation
import LyktaCore
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(NotificationRegistration.registered(PushToken(deviceToken)), subject: application)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        NotificationCenter.default.post(NotificationRegistration.failed(error.localizedDescription), subject: application)
    }
}

enum NotificationRegistration: NotificationCenter.MainActorMessage {
    typealias Subject = UIApplication

    case registered(PushToken)
    case failed(String)
}
