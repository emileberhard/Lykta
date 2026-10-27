import Foundation
import LyktaCore

struct WidgetRequest: Decodable, Sendable {
    let title: String?
    let layout: JSONValue?
    let data: JSONValue?
    let now: [String: Double]?
    let ifRevision: Int?
    let staleAfter: Int?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case title, layout, data, now, ifRevision, staleAfter
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: WidgetKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let key = fields.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(forKey: key, in: fields, debugDescription: "Unknown key \"\(key.stringValue)\".")
        }
        title = try fields.decodeIfPresent(String.self, forKey: WidgetKey(stringValue: "title"))
        layout = try fields.decodeIfPresent(JSONValue.self, forKey: WidgetKey(stringValue: "layout"))
        data = try fields.decodeIfPresent(JSONValue.self, forKey: WidgetKey(stringValue: "data"))
        now = try fields.decodeIfPresent([String: Double].self, forKey: WidgetKey(stringValue: "now"))
        ifRevision = try fields.decodeIfPresent(Int.self, forKey: WidgetKey(stringValue: "ifRevision"))
        staleAfter = try fields.decodeIfPresent(Int.self, forKey: WidgetKey(stringValue: "staleAfter"))
        func invalid(_ key: String, _ message: String) throws -> Never {
            throw DecodingError.dataCorruptedError(forKey: WidgetKey(stringValue: key), in: fields, debugDescription: message)
        }
        if let title, !(1...120).contains(title.count) { try invalid("title", "must be 1 to 120 characters") }
        if let staleAfter, staleAfter <= 0 { try invalid("staleAfter", "must be positive seconds") }
        if let ifRevision, ifRevision < 1 { try invalid("ifRevision", "must be a revision from GET /v1/widgets/{name}") }
        let paths = now?.keys.sorted() ?? []
        for path in paths {
            if !(1...256).contains(path.utf8.count) || path.contains("{{") || path.split(separator: ".", omittingEmptySubsequences: false).contains("") {
                try invalid("now", "\"\(path)\" is not a data path such as \"timer.ends\"")
            }
            if paths.contains(where: { $0.hasPrefix(path + ".") }) { try invalid("now", "\"\(path)\" overlaps another path; set each value once") }
        }
        if now?.values.allSatisfy(\.isFinite) == false { try invalid("now", "takes finite numbers of seconds") }
    }
}

struct WidgetStatus: Encodable, Sendable {
    enum Delivery: String, Encodable, Sendable { case notPlaced, pending, accepted, fetched, failed }
    struct Fetch: Encodable, Sendable {
        let revision: Int
        let at: Date
    }

    let name: Name
    let id: UUID
    let title: String
    let revision: Int
    let delivery: Delivery
    let nextPush: Date?
    let error: String?
    let placed: [WidgetLayout.Family]
    let fetched: Fetch?
    let createdAt: Date
    let updatedAt: Date
}

struct WidgetDetail: Encodable, Sendable {
    let status: WidgetStatus
    let layout: JSONValue
    let data: JSONValue

    func encode(to encoder: any Encoder) throws {
        try status.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(layout, forKey: .layout)
        try fields.encode(data, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey { case layout, data }
}

struct Widget: Sendable {
    let id: UUID
    let deviceID: UUID
    let name: Name
    let title: String
    let layout: JSONValue
    let data: JSONValue
    let content: JSONValue
    let requires: Version
    let staleAfter: Int?
    let revision: Int
    let generation: Int?
    let createdAt: Int
    let updatedAt: Int

    init(_ row: Row) throws {
        id = try row.text("id", as: UUID.init(uuidString:))
        deviceID = try row.text("device_id", as: UUID.init(uuidString:))
        name = try row.text("name", as: Name.init(rawValue:))
        title = try row.string("title")
        let decoder = JSONDecoder()
        layout = try decoder.decode(JSONValue.self, from: Data(row.string("layout").utf8))
        data = try decoder.decode(JSONValue.self, from: Data(row.string("data").utf8))
        content = try decoder.decode(JSONValue.self, from: Data(row.string("content").utf8))
        requires = try row.text("requires", as: Version.init)
        staleAfter = try row.optionalInteger("stale_after").map(Int.init)
        revision = Int(try row.integer("revision"))
        generation = try row.optionalInteger("generation").map(Int.init)
        createdAt = Int(try row.integer("created_at"))
        updatedAt = Int(try row.integer("updated_at"))
    }
}

private struct WidgetKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
