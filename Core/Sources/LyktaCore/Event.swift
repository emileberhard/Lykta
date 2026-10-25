import Foundation

public struct Event: Codable, Sendable {
    public static let maximumDetailBytes = 262_144

    public let id: UUID
    public let at: Date
    public let name: String
    public let activity: UUID?
    public let detail: JSONValue

    public init(id: UUID, at: Date, name: String, activity: UUID?, detail: JSONValue) {
        self.id = id
        self.at = at
        self.name = name
        self.activity = activity
        self.detail = detail
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(["id", "at", "name", "activity", "detail"])
        id = try fields.required("id")
        at = try fields.required("at")
        name = try fields.required("name")
        activity = try fields.optional("activity")
        detail = try fields.required("detail")
        guard Self.isName(name) else { throw fields.invalid("must be 1 to 48 of a-z, A-Z, 0-9, '.' or '_'", at: "name") }
        guard case .object = detail else { throw fields.invalid("must be an object", at: "detail") }
        guard detail.json.count <= Self.maximumDetailBytes else {
            throw fields.invalid("must encode to at most \(Self.maximumDetailBytes) bytes", at: "detail")
        }
    }

    private static func isName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._".utf8)
        return (1...48).contains(name.utf8.count) && name.utf8.allSatisfy(allowed.contains)
    }
}

public struct EventBatch: Codable, Sendable {
    public static let maximumEvents = 100

    public let events: [Event]

    public init(events: [Event]) {
        self.events = events
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        events = try fields.required("events")
        guard (1...Self.maximumEvents).contains(events.count) else {
            throw fields.invalid("must hold 1 to \(Self.maximumEvents) events", at: "events")
        }
    }
}

public func fingerprint(_ bytes: some Sequence<UInt8>) -> String {
    String(fnv1a(bytes), radix: 16)
}

func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}
