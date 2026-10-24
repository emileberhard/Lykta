import CryptoKit
import Foundation
import Intents
import LyktaCore
import UIKit
import UserNotifications

nonisolated final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let original = request.content
        guard let payload = Self.payload(of: original) else { return contentHandler(original) }
        let sound: NotificationReport.Sound = original.sound == nil ? .none : .default
        do {
            let content = try Self.communication(original, sender: payload.sender)
            Self.report(NotificationReport(style: .communication(.initials), sound: sound), for: payload)
            contentHandler(content)
        } catch {
            Self.report(NotificationReport(style: .plain, sound: sound), for: payload)
            contentHandler(original)
        }
    }

    private static func payload(of content: UNNotificationContent) -> NotificationPayload? {
        guard let object = content.userInfo[NotificationPayload.key], JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(NotificationPayload.self, from: data)
    }

    private static func communication(_ content: UNNotificationContent, sender id: String) throws -> UNNotificationContent {
        let sender = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil, displayName: content.title,
                              image: INImage(imageData: initials(of: content.title, colored: id)), contactIdentifier: nil,
                              customIdentifier: id, isMe: false, suggestionType: .none)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body,
                                         speakableGroupName: nil, conversationIdentifier: id, serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        return try content.updating(from: intent)
    }

    private static func initials(of name: String, colored seed: String) -> Data {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { $0.uppercased() }.joined()
        let hue = CGFloat(SHA256.hash(data: Data(seed.utf8)).withUnsafeBytes { $0[0] }) / 256
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: hue, saturation: 0.65, brightness: 0.75, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let text = NSAttributedString(string: letters, attributes: [
                .font: UIFont.systemFont(ofSize: letters.count > 1 ? 100 : 120, weight: .semibold), .foregroundColor: UIColor.white,
            ])
            let bounds = text.size()
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
    }

    private static func report(_ report: NotificationReport, for payload: NotificationPayload) {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "LyktaGatewayHost") as? String, !host.isEmpty,
              let url = URL(string: "https://\(host)/v1/device/notifications/\(payload.id.uuidString)/report"),
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

nonisolated private final class RefusingRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
