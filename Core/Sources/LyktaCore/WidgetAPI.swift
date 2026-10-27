import Foundation

public struct WidgetCredential: Codable, Sendable {
    public let widgetToken: String

    public init(widgetToken: String) {
        self.widgetToken = widgetToken
    }
}

public struct WidgetPlace: Codable, Hashable, Sendable {
    public let widget: UUID
    public let family: WidgetLayout.Family

    public init(widget: UUID, family: WidgetLayout.Family) {
        self.widget = widget
        self.family = family
    }
}

public struct WidgetReport: Codable, Sendable {
    public static let maximumPlaces = 256

    public let pushToken: PushToken?
    public let layoutVersion: Version
    public let places: [WidgetPlace]

    public init(pushToken: PushToken?, layoutVersion: Version, places: [WidgetPlace]) {
        self.pushToken = pushToken
        self.layoutVersion = layoutVersion
        self.places = places
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(["pushToken", "layoutVersion", "places"])
        pushToken = try fields.optional("pushToken")
        layoutVersion = try fields.required("layoutVersion")
        places = try fields.required("places")
        guard places.count <= Self.maximumPlaces else {
            throw fields.invalid("must list at most \(Self.maximumPlaces) places", at: "places")
        }
    }
}

public struct WidgetSummary: Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date

    public init(id: UUID, title: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        id = try fields.required("id")
        title = try fields.required("title")
        updatedAt = try fields.date(fields.required("updatedAt"), at: "updatedAt")
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(id, forKey: Key(stringValue: "id"))
        try fields.encode(title, forKey: Key(stringValue: "title"))
        try fields.encode(updatedAt.formatted(.iso8601), forKey: Key(stringValue: "updatedAt"))
    }
}

public struct WidgetSnapshot: Codable, Sendable {
    public enum Content: Equatable, Sendable {
        case layout(JSONValue)
        case requires(Version)
    }

    public let id: UUID
    public let title: String
    public let revision: Int
    public let staleAt: Date?
    public let content: Content

    public init(id: UUID, title: String, revision: Int, staleAt: Date?, content: Content) {
        self.id = id
        self.title = title
        self.revision = revision
        self.staleAt = staleAt
        self.content = content
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        id = try fields.required("id")
        title = try fields.required("title")
        revision = try fields.required("revision")
        staleAt = try fields.optional("staleAt").map { try fields.date($0, at: "staleAt") }
        if let layout: JSONValue = try fields.optional("layout") {
            content = .layout(layout)
        } else {
            content = .requires(try fields.required("requires"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: Key.self)
        try fields.encode(id, forKey: Key(stringValue: "id"))
        try fields.encode(title, forKey: Key(stringValue: "title"))
        try fields.encode(revision, forKey: Key(stringValue: "revision"))
        try fields.encodeIfPresent(staleAt?.formatted(.iso8601), forKey: Key(stringValue: "staleAt"))
        switch content {
        case let .layout(layout): try fields.encode(layout, forKey: Key(stringValue: "layout"))
        case let .requires(version): try fields.encode(version, forKey: Key(stringValue: "requires"))
        }
    }
}
