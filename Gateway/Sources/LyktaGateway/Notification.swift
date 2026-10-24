import Foundation
import LyktaCore

struct NotificationRequest: Codable, Equatable, Sendable {
    struct Sender: Codable, Equatable, Sendable {
        let id: Name
        let name: String
    }

    let sender: Sender
    let body: String
    let sound: Bool?

    static func decode(_ value: JSONValue) throws(APIError) -> NotificationRequest {
        guard case let .object(fields) = value else { throw invalid("Send a JSON object.") }
        try allowOnly(["sender", "body", "sound"], in: fields, at: nil)
        guard case let .object(sender)? = fields["sender"] else {
            throw invalid("sender must be an object with the sender's id and name.")
        }
        try allowOnly(["id", "name"], in: sender, at: "sender")
        guard case let .string(id)? = sender["id"], let senderID = Name(rawValue: id) else {
            throw invalid("sender.id names the sender: 1 to 64 lowercase letters, digits, '-', '_' or '.', the same for every notification it sends.")
        }
        guard case let .string(name)? = sender["name"], (1...64).contains(name.count) else {
            throw invalid("sender.name must be 1 to 64 characters; it is the notification's title.")
        }
        guard case let .string(body)? = fields["body"], (1...500).contains(body.count) else {
            throw invalid("body must be 1 to 500 characters.")
        }
        let sound: Bool?
        switch fields["sound"] {
        case nil: sound = nil
        case .bool(true)?: sound = true
        default: throw invalid("sound must be true for the default sound; leave it out for a silent notification.")
        }
        return NotificationRequest(sender: Sender(id: senderID, name: name), body: body, sound: sound)
    }

    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    func payload(id: UUID, token: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(Payload(
            aps: .init(alert: .init(title: sender.name, body: body), sound: sound == true ? "default" : nil, threadID: sender.id.rawValue),
            lykta: NotificationPayload(id: id, sender: sender.id.rawValue, token: token)))
    }

    private struct Payload: Encodable {
        struct APS: Encodable {
            struct Alert: Encodable {
                let title: String
                let body: String
            }

            let alert: Alert
            let sound: String?
            let mutableContent = 1
            let threadID: String

            enum CodingKeys: String, CodingKey {
                case alert, sound
                case mutableContent = "mutable-content", threadID = "thread-id"
            }
        }

        let aps: APS
        let lykta: NotificationPayload
    }

    private static func allowOnly(_ allowed: Set<String>, in fields: [String: JSONValue], at path: String?) throws(APIError) {
        if let key = fields.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw invalid("Unknown key \"\(path.map { "\($0)." } ?? "")\(key)\"; expected \(allowed.sorted().joined(separator: ", ")).")
        }
    }

    private static func invalid(_ message: String) -> APIError {
        APIError(.invalidRequest, message)
    }
}

struct NotificationStatus: Encodable, Sendable {
    enum State: String, Encodable, Sendable {
        case queued, sent, received, failed, unknown
    }

    enum Banners: String, Encodable, Sendable {
        case temporary, persistent, off
    }

    let name: Name
    let state: State
    let error: String?
    let phone: NotificationReport?
    let banners: Banners?
    let createdAt: Date
    let expires: Date

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name)
        try fields.encode(state, forKey: .state)
        try fields.encode(error, forKey: .error)
        try fields.encode(phone, forKey: .phone)
        try fields.encode(banners, forKey: .banners)
        try fields.encode(createdAt, forKey: .createdAt)
        try fields.encode(expires, forKey: .expires)
    }

    private enum CodingKeys: String, CodingKey {
        case name, state, error, phone, banners, createdAt, expires
    }
}

extension NotificationStatus.Banners {
    init?(_ style: NotificationSettings.AlertStyle?) {
        switch style {
        case nil: return nil
        case .banner?: self = .temporary
        case .alert?: self = .persistent
        case NotificationSettings.AlertStyle.none?: self = .off
        }
    }
}
