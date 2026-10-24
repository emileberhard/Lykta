import Foundation

public enum PushEnvironment: String, Choice, Encodable {
    case development, production
}

public enum ObservedState: String, Choice, Encodable {
    case pending, active, stale, ended, dismissed, unknown
}

public struct PushToken: Codable, Hashable, Sendable, CustomStringConvertible {
    public static let maximumBytes = 128

    public let description: String

    public init(_ bytes: Data) {
        precondition((1...Self.maximumBytes).contains(bytes.count), "APNs tokens have 1 to \(Self.maximumBytes) bytes")
        description = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public init?(hex: String) {
        let digits = Set("0123456789abcdef".utf8)
        guard hex.utf8.count.isMultiple(of: 2), (2...2 * Self.maximumBytes).contains(hex.utf8.count),
              hex.utf8.allSatisfy(digits.contains) else { return nil }
        description = hex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let token = Self(hex: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected lowercase hex of 1 to \(Self.maximumBytes) bytes")
        }
        self = token
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct Registration: Codable, Sendable {
    public enum Proof: Sendable {
        case attestation(keyID: Data, object: Data, challenge: Data)
        case invite(String)
    }

    public let environment: PushEnvironment
    public let appVersion: String
    public let proof: Proof

    public init(environment: PushEnvironment, appVersion: String, proof: Proof) {
        self.environment = environment
        self.appVersion = appVersion
        self.proof = proof
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        environment = try fields.required("environment")
        appVersion = try fields.text("appVersion", maximumLength: DeviceReport.maximumAppVersionLength)
        if let invite: String = try fields.optional("invite") {
            try fields.allowOnly(["environment", "appVersion", "invite"])
            proof = .invite(invite)
        } else {
            try fields.allowOnly(["environment", "appVersion", "keyID", "attestation", "challenge"])
            proof = .attestation(keyID: try fields.required("keyID"), object: try fields.required("attestation"), challenge: try fields.required("challenge"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(environment, forKey: Key(stringValue: "environment"))
        try fields.encode(appVersion, forKey: Key(stringValue: "appVersion"))
        switch proof {
        case let .attestation(keyID, object, challenge):
            try fields.encode(keyID, forKey: Key(stringValue: "keyID"))
            try fields.encode(object, forKey: Key(stringValue: "attestation"))
            try fields.encode(challenge, forKey: Key(stringValue: "challenge"))
        case let .invite(code):
            try fields.encode(code, forKey: Key(stringValue: "invite"))
        }
    }
}

public struct Challenge: Codable, Sendable {
    public let challenge: Data

    public init(challenge: Data) {
        self.challenge = challenge
    }
}

public struct Credentials: Codable, Sendable {
    public let deviceSecret: String
    public let agentToken: String

    public init(deviceSecret: String, agentToken: String) {
        self.deviceSecret = deviceSecret
        self.agentToken = agentToken
    }
}

public struct DeviceReport: Codable, Sendable {
    public static let maximumAppVersionLength = 32
    public static let maximumActivities = 64

    public struct Observed: Codable, Sendable {
        public let id: UUID
        public let state: ObservedState

        public init(id: UUID, state: ObservedState) {
            self.id = id
            self.state = state
        }
    }

    public let pushToStartToken: PushToken?
    public let appVersion: String
    public let layoutVersion: Version?
    public let bundleInstance: UUID
    public let activities: [Observed]
    public let notifications: NotificationSettings?

    public init(pushToStartToken: PushToken?, appVersion: String, layoutVersion: Version, bundleInstance: UUID, activities: [Observed],
                notifications: NotificationSettings) {
        self.pushToStartToken = pushToStartToken
        self.appVersion = appVersion
        self.layoutVersion = layoutVersion
        self.bundleInstance = bundleInstance
        self.activities = activities
        self.notifications = notifications
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        pushToStartToken = try fields.optional("pushToStartToken")
        appVersion = try fields.text("appVersion", maximumLength: Self.maximumAppVersionLength)
        layoutVersion = try fields.optional("layoutVersion")
        bundleInstance = try fields.required("bundleInstance")
        activities = try fields.required("activities")
        notifications = try fields.optional("notifications")
        guard activities.count <= Self.maximumActivities else {
            throw fields.invalid("must list at most \(Self.maximumActivities) activities", at: "activities")
        }
    }
}

public struct SyncResult: Codable, Sendable {
    public let end: [UUID]

    public init(end: [UUID]) {
        self.end = end
    }
}

public struct Action: Codable, Equatable, Sendable {
    public enum Input: Encodable, Equatable, Sendable {
        case button(String)
        case toggle(String, isOn: Bool)

        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: Key.self)
            switch self {
            case let .button(name):
                try fields.encode(name, forKey: Key(stringValue: "button"))
            case let .toggle(path, isOn):
                try fields.encode(path, forKey: Key(stringValue: "toggle"))
                try fields.encode(isOn, forKey: Key(stringValue: "isOn"))
            }
        }
    }

    public let id: UUID
    public let activity: UUID
    public let input: Input

    public init(id: UUID, activity: UUID, input: Input) {
        self.id = id
        self.activity = activity
        self.input = input
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(["id", "activity", "button", "toggle", "isOn"])
        id = try fields.required("id")
        activity = try fields.required("activity")
        if let button: String = try fields.optional("button") {
            guard Node.Content.isName(button) else { throw fields.invalid("not a button name", at: "button") }
            guard !fields.contains(Key(stringValue: "toggle")), !fields.contains(Key(stringValue: "isOn")) else {
                throw fields.invalid("an action is a button or a toggle with isOn")
            }
            input = .button(button)
        } else {
            input = .toggle(try fields.text("toggle", maximumLength: 256), isOn: try fields.required("isOn"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(id, forKey: Key(stringValue: "id"))
        try fields.encode(activity, forKey: Key(stringValue: "activity"))
        try input.encode(to: encoder)
    }
}

public struct NotificationSettings: Codable, Equatable, Sendable {
    public enum Authorization: String, Choice, Encodable {
        case notDetermined, denied, authorized, provisional, ephemeral
    }

    public enum AlertStyle: String, Choice, Encodable {
        case none, banner, alert
    }

    public let authorization: Authorization
    public let alertStyle: AlertStyle
    public let token: PushToken?

    public init(authorization: Authorization, alertStyle: AlertStyle, token: PushToken?) {
        self.authorization = authorization
        self.alertStyle = alertStyle
        self.token = token
    }
}

public struct NotificationPayload: Codable, Sendable {
    public static let key = "lykta"

    public let id: UUID
    public let sender: String
    public let token: String

    public init(id: UUID, sender: String, token: String) {
        self.id = id
        self.sender = sender
        self.token = token
    }
}

public struct NotificationReport: Codable, Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        case communication(Avatar)
        case plain
    }

    public enum Avatar: String, Choice, Encodable {
        case image, initials
    }

    public enum Sound: String, Choice, Encodable {
        case custom, `default`, none
    }

    public let style: Style
    public let sound: Sound

    public init(style: Style, sound: Sound) {
        self.style = style
        self.sound = sound
    }

    public init(from decoder: any Decoder) throws {
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

    public func encode(to encoder: any Encoder) throws {
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
