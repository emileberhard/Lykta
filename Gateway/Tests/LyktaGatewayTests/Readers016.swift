import Foundation
@testable import LyktaCore

enum Readers016 {
    struct NotificationRequest: Codable {
    struct Sender: Codable, Equatable, Sendable {
        let id: Name
        let name: String
        let avatar: MediaID?
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

        let sender: Sender
        let body: String
        let sound: Sound?
        let image: MediaID?
    }

struct NotificationReport: Codable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case communication(Avatar)
        case plain
    }

    enum Avatar: String, Choice, Encodable {
        case image, initials
    }

    enum Sound: String, Choice, Encodable {
        case custom, `default`, none
    }

    let style: Style
    let sound: Sound

    init(style: Style, sound: Sound) {
        self.style = style
        self.sound = sound
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        sound = try fields.required("sound")
        switch try fields.required("style") as String {
        case "communication":
            try fields.allowOnly(["style", "avatar", "sound"])
            style = .communication(try fields.required("avatar"))
        case "plain":
            try fields.allowOnly(["style", "sound"])
            style = .plain
        default:
            throw fields.invalid("must be communication or plain", at: "style")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        switch style {
        case let .communication(avatar):
            try fields.encode("communication", forKey: Key(stringValue: "style"))
            try fields.encode(avatar, forKey: Key(stringValue: "avatar"))
        case .plain:
            try fields.encode("plain", forKey: Key(stringValue: "style"))
        }
        try fields.encode(sound, forKey: Key(stringValue: "sound"))
    }
}

}
