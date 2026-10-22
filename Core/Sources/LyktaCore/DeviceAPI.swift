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
    public let environment: PushEnvironment
    public let appVersion: String

    public init(environment: PushEnvironment, appVersion: String) {
        self.environment = environment
        self.appVersion = appVersion
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        environment = try fields.required("environment")
        appVersion = try fields.text("appVersion", maximumLength: DeviceReport.maximumAppVersionLength)
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

    public init(pushToStartToken: PushToken?, appVersion: String, layoutVersion: Version, bundleInstance: UUID, activities: [Observed]) {
        self.pushToStartToken = pushToStartToken
        self.appVersion = appVersion
        self.layoutVersion = layoutVersion
        self.bundleInstance = bundleInstance
        self.activities = activities
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        pushToStartToken = try fields.optional("pushToStartToken")
        appVersion = try fields.text("appVersion", maximumLength: Self.maximumAppVersionLength)
        layoutVersion = try fields.optional("layoutVersion")
        bundleInstance = try fields.required("bundleInstance")
        activities = try fields.required("activities")
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
