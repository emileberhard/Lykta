import Foundation
import Intents
import LyktaCore
import Synchronization
import UserNotifications

nonisolated final class NotificationService: UNNotificationServiceExtension {
    private enum Delivery {
        case idle
        case pending(UNNotificationContent, (UNNotificationContent) -> Void)
        case finished
    }

    private let deliveryLock = NSLock()
    private var delivery = Delivery.idle

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        deliveryLock.withLock { delivery = .pending(original, contentHandler) }
        guard let payload = Self.payload(of: original), let host = Self.host, let content = original.mutableCopy() as? UNMutableNotificationContent else {
            return finish()
        }
        let loader = MediaLoader(payload: payload, host: host, cache: .shared)
        defer { loader.release() }
        let media = loader.load(within: 20)
        var sound: NotificationReport.Sound = original.sound == nil ? .none : .default
        if let file = media.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(file))
            sound = .custom
        }
        if let image = media.image {
            do {
                content.attachments = [try UNNotificationAttachment(identifier: "image", url: image)]
            } catch {
                try? FileManager.default.removeItem(at: image)
            }
        }
        guard keep(content) else { return }
        var avatar = media.avatar
        var failure: PackedNode.Failure?
        if avatar == nil, let drawing = payload.drawing {
            do { avatar = try DrawnAvatar.png(drawing.node()) }
            catch { failure = error }
        }
        let intent = Self.intent(content, sender: payload.sender, avatar: avatar)
        if Self.donate(intent, within: 3), let communication = try? content.updating(from: intent) {
            guard keep(communication) else { return }
            Self.report(NotificationReport(style: .communication(avatar == nil ? .initials : .image), sound: sound), failure: failure, for: payload, to: host)
            finish()
        } else {
            Self.report(NotificationReport(style: .plain, sound: sound), failure: failure, for: payload, to: host)
            finish()
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func keep(_ content: UNNotificationContent) -> Bool {
        deliveryLock.withLock {
            guard case let .pending(_, handler) = delivery else { return false }
            delivery = .pending(content.copy() as! UNNotificationContent, handler)
            return true
        }
    }

    private func finish() {
        let ready = deliveryLock.withLock {
            let ready = delivery
            delivery = .finished
            return ready
        }
        if case let .pending(content, handler) = ready { handler(content) }
    }

    private static var host: String? {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "LyktaGatewayHost") as? String, !host.isEmpty else { return nil }
        return host
    }

    private static func payload(of content: UNNotificationContent) -> NotificationPayload? {
        guard let object = content.userInfo[NotificationPayload.key], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(NotificationPayload.self, from: data)
    }

    private static func intent(_ content: UNNotificationContent, sender id: String, avatar: Data?) -> INSendMessageIntent {
        let sender = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil, displayName: content.title,
                              image: INImage(imageData: avatar ?? Initials.avatar(of: content.title, sender: id)), contactIdentifier: nil,
                              customIdentifier: id, isMe: false, suggestionType: .none)
        return INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                   speakableGroupName: nil, conversationIdentifier: id, serviceName: nil, sender: sender, attachments: nil)
    }

    private static func donate(_ intent: INSendMessageIntent, within seconds: Double) -> Bool {
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        let donation = Donation()
        interaction.donate { donation.finish(succeeded: $0 == nil) }
        return donation.succeeded(within: seconds)
    }

    private static func report(_ report: NotificationReport, failure: PackedNode.Failure?, for payload: NotificationPayload, to host: String) {
        guard let url = URL(string: "https://\(host)/v1/device/notifications/\(payload.id.uuidString)/report"),
              let body = try? JSONEncoder().encode(report) else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = failure.map { [URLQueryItem(name: "avatarFailure", value: $0.rawValue)] }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral, delegate: RefusingRedirects(), delegateQueue: nil)
        let reported = DispatchSemaphore(value: 0)
        session.uploadTask(with: request, from: body) { _, _, _ in reported.signal() }.resume()
        _ = reported.wait(timeout: .now() + 3)
        session.invalidateAndCancel()
    }
}

private nonisolated final class Donation: Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let outcome = Mutex(false)

    func finish(succeeded: Bool) {
        outcome.withLock { $0 = succeeded }
        finished.signal()
    }

    func succeeded(within seconds: Double) -> Bool {
        finished.wait(timeout: .now() + seconds) == .success && outcome.withLock { $0 }
    }
}
