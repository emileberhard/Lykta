import Foundation
import Intents
import LyktaCore
import UserNotifications

nonisolated final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        guard let payload = Self.payload(of: original), let host = Self.host, let content = original.mutableCopy() as? UNMutableNotificationContent else {
            return contentHandler(original)
        }
        let media = MediaLoader(payload: payload, host: host, appGroup: Bundle.main.object(forInfoDictionaryKey: "LyktaAppGroup") as? String)
            .load(within: 20)
        var sound: NotificationReport.Sound = original.sound == nil ? .none : .default
        if let file = media.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(file))
            sound = .custom
        }
        if let image = media.image, let attachment = try? UNNotificationAttachment(identifier: "image", url: image) {
            content.attachments = [attachment]
        }
        do {
            let communication = try Self.communication(content, sender: payload.sender, avatar: media.avatar)
            Self.report(NotificationReport(style: .communication(media.avatar == nil ? .initials : .image), sound: sound), for: payload, to: host)
            contentHandler(communication)
        } catch {
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

    private static func communication(_ content: UNNotificationContent, sender id: String, avatar: Data?) throws -> UNNotificationContent {
        let sender = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil, displayName: content.title,
                              image: INImage(imageData: avatar ?? Initials.avatar(of: content.title, sender: id)), contactIdentifier: nil,
                              customIdentifier: id, isMe: false, suggestionType: .none)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: id, serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try content.updating(from: intent)
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
