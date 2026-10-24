import Foundation
import Intents
import LyktaCore
import Synchronization
import UserNotifications

nonisolated final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        guard let payload = Self.payload(of: original), let host = Self.host, let content = original.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(original)
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
        let intent = Self.intent(content, sender: payload.sender, avatar: media.avatar)
        if Self.donate(intent, within: 3), let communication = try? content.updating(from: intent) {
            Self.report(NotificationReport(style: .communication(media.avatar == nil ? .initials : .image), sound: sound), for: payload, to: host)
            contentHandler(communication)
        } else {
            Self.report(NotificationReport(style: .plain, sound: sound), for: payload, to: host)
            contentHandler(content)
        }
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

    private static func report(_ report: NotificationReport, for payload: NotificationPayload, to host: String) {
        guard let url = URL(string: "https://\(host)/v1/device/notifications/\(payload.id.uuidString)/report"),
              let body = try? JSONEncoder().encode(report) else { return }
        var request = URLRequest(url: url)
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
