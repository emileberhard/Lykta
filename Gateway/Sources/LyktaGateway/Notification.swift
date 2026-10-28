import Foundation
import LyktaCore

struct NotificationRequest: Codable, Equatable, Sendable {
    enum Avatar: Equatable, Sendable {
        case medium(MediaID)
        case drawing(JSONValue)
    }

    struct Sender: Codable, Equatable, Sendable {
        let id: Name
        let name: String
        let avatar: Avatar?

        init(id: Name, name: String, avatar: Avatar?) {
            self.id = id
            self.name = name
            self.avatar = avatar
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(Name.self, forKey: .id)
            name = try fields.decode(String.self, forKey: .name)
            if let drawing = try fields.decodeIfPresent(JSONValue.self, forKey: .drawing) {
                guard !fields.contains(.avatar) else {
                    throw DecodingError.dataCorruptedError(forKey: .drawing, in: fields, debugDescription: "a sender has one avatar")
                }
                avatar = .drawing(drawing)
            } else { avatar = try fields.decodeIfPresent(MediaID.self, forKey: .avatar).map(Avatar.medium) }
        }

        func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(id, forKey: .id)
            try fields.encode(name, forKey: .name)
            switch avatar {
            case let .medium(id)?: try fields.encode(id, forKey: .avatar)
            case let .drawing(node)?: try fields.encode(node, forKey: .drawing)
            case nil: break
            }
        }

        private enum CodingKeys: String, CodingKey { case id, name, avatar, drawing }
    }

    enum Sound: Equatable, Sendable, Codable {
        case `default`
        case medium(MediaID)

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let isOn = try? container.decode(Bool.self), isOn {
                self = .default
            } else {
                self = .medium(try container.decode(MediaID.self))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .default: try container.encode(true)
            case let .medium(id): try container.encode(id)
            }
        }
    }

    struct Reference: Sendable {
        let path: String
        let id: MediaID
        let kind: Medium.Kind
    }

    let sender: Sender
    let body: String
    let sound: Sound?
    let image: MediaID?

    var references: [Reference] {
        var references: [Reference] = []
        if case let .medium(avatar)? = sender.avatar { references.append(Reference(path: "sender.avatar", id: avatar, kind: .image)) }
        if case let .medium(id)? = sound { references.append(Reference(path: "sound", id: id, kind: .sound)) }
        if let image { references.append(Reference(path: "image", id: image, kind: .image)) }
        return references
    }

    static func decode(_ value: JSONValue) throws(APIError) -> NotificationRequest {
        guard case let .object(fields) = value else { throw invalid("Send a JSON object.") }
        try allowOnly(["sender", "body", "sound", "image"], in: fields, at: nil)
        guard case let .object(sender)? = fields["sender"] else {
            throw invalid("sender must be an object with the sender's id and name.")
        }
        try allowOnly(["id", "name", "avatar"], in: sender, at: "sender")
        guard case let .string(id)? = sender["id"], let senderID = Name(rawValue: id) else {
            throw invalid("sender.id names the sender: 1 to 64 lowercase letters, digits, '-', '_' or '.', the same for every notification it sends.")
        }
        guard case let .string(name)? = sender["name"], (1...64).contains(name.count) else {
            throw invalid("sender.name must be 1 to 64 characters; it is the notification's title.")
        }
        guard case let .string(body)? = fields["body"], (1...500).contains(body.count) else {
            throw invalid("body must be 1 to 500 characters.")
        }
        let sound: Sound?
        switch fields["sound"] {
        case nil: sound = nil
        case .bool(true)?: sound = .default
        case let .string(text)? where MediaID(rawValue: text) != nil: sound = .medium(MediaID(rawValue: text)!)
        default: throw invalid("sound must be true for the default sound or the id of a sound from POST /v1/media; leave it out for silence.")
        }
        let avatar: Avatar?
        if case let .object(node)? = sender["avatar"] { avatar = .drawing(.object(node)) }
        else { avatar = try medium(sender["avatar"], at: "sender.avatar").map(Avatar.medium) }
        return NotificationRequest(sender: Sender(id: senderID, name: name, avatar: avatar),
                                   body: body, sound: sound, image: try medium(fields["image"], at: "image"))
    }

    private static func medium(_ value: JSONValue?, at path: String) throws(APIError) -> MediaID? {
        switch value {
        case nil: return nil
        case let .string(text)?:
            if let id = MediaID(rawValue: text) { return id }
            fallthrough
        default: throw invalid("\(path) must be the id of an image from POST /v1/media, such as m_0123456789abcdef0123456789abcdef."
                          + (path == "sender.avatar" ? " For a drawn avatar, send a node object such as {\"text\":\"ET\"}." : ""))
        }
    }

    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }

    func payload(id: UUID, token: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let avatar: MediaID?
        let drawing: PackedNode?
        switch sender.avatar {
        case let .medium(id)?: avatar = id; drawing = nil
        case let .drawing(node)?: avatar = nil; drawing = try PackedNode(packing: node)
        case nil: avatar = nil; drawing = nil
        }
        return try encoder.encode(Payload(
            aps: .init(alert: .init(title: sender.name, body: body), sound: sound == nil ? nil : "default", threadID: sender.id.rawValue),
            lykta: NotificationPayload(id: id, sender: sender.id.rawValue, token: token, avatar: avatar, drawing: drawing, sound: soundMedium, image: image)))
    }

    private var soundMedium: MediaID? {
        if case let .medium(id)? = sound { id } else { nil }
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
