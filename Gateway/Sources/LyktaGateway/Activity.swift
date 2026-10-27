import Foundation
import LyktaCore

struct Name: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".utf8)
        guard (1...64).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy(allowed.contains) else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

enum DeliveryState: String, Encodable, Sendable {
    case pending, accepted, throttled, unknown, failed
}

struct Alert: Codable, Equatable, Sendable {
    let title: String?
    let body: String
    let sound: Bool?
}

struct ActivityRequest: Decodable, Sendable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case title, layout, data, now, alert, staleAfter, endAfter, relevance, ifRevision
    }

    let title: String?
    let layout: JSONValue?
    let data: JSONValue?
    let now: [String: Double]?
    let alert: Alert?
    let staleAfter: Int?
    let endAfter: Int?
    let relevance: Double?
    let ifRevision: Int?
}

struct ActivityStatus: Encodable, Sendable {
    let name: Name
    let id: UUID
    let title: String
    let state: Activity.Phase
    let revision: Int
    let delivery: DeliveryState
    let device: ObservedState?
    let error: String?
    let layoutReadable: Bool?
    let startedAt: Date
    let endedAt: Date?

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name)
        try fields.encode(id, forKey: .id)
        try fields.encode(title, forKey: .title)
        try fields.encode(state, forKey: .state)
        try fields.encode(revision, forKey: .revision)
        try fields.encode(delivery, forKey: .delivery)
        try fields.encode(device, forKey: .device)
        try fields.encode(error, forKey: .error)
        try fields.encode(layoutReadable, forKey: .layoutReadable)
        try fields.encode(startedAt, forKey: .startedAt)
        try fields.encode(endedAt, forKey: .endedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case name, id, title, state, revision, delivery, device, error, layoutReadable, startedAt, endedAt
    }
}

struct ActivityDetail: Encodable, Sendable {
    let status: ActivityStatus
    let data: JSONValue

    func encode(to encoder: any Encoder) throws {
        try status.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(data, forKey: .data)
    }

    private enum CodingKeys: String, CodingKey {
        case data
    }
}

struct ActivityPut: Encodable, Sendable {
    let detail: ActivityDetail
    let payloadBytes: Int

    func encode(to encoder: any Encoder) throws {
        try detail.encode(to: encoder)
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(payloadBytes, forKey: .payloadBytes)
    }

    private enum CodingKeys: String, CodingKey {
        case payloadBytes
    }
}

struct Activity: Sendable {
    enum Phase: String, Encodable, Sendable {
        case starting, live, ending, ended
    }

    let id: UUID
    let deviceID: UUID
    let name: Name
    let phase: Phase
    let title: String
    let layout: String
    let data: String
    let content: String
    let staleAfter: Int?
    let endsAt: Int?
    let relevance: Double?
    let alert: Alert?
    let dismissAt: Int?
    let revision: Int
    let sentRevision: Int
    let channel: String?
    let channelEnvironment: PushEnvironment?
    let failures: Int
    let delivery: DeliveryState
    let error: String?
    let deviceState: ObservedState?
    let createdAt: Int
    let updatedAt: Int?
    let endedAt: Int?

    init(_ row: Row) throws {
        id = try row.text("id", as: UUID.init(uuidString:))
        deviceID = try row.text("device_id", as: UUID.init(uuidString:))
        name = try row.text("name", as: Name.init(rawValue:))
        phase = try row.text("phase", as: Phase.init(rawValue:))
        title = try row.string("title")
        layout = try row.string("layout")
        data = try row.string("data")
        content = try row.string("content")
        staleAfter = try row.optionalInteger("stale_after").map(Int.init)
        endsAt = try row.optionalInteger("ends_at").map(Int.init)
        relevance = try row.optionalReal("relevance")
        alert = try row.optionalString("alert").map { try JSONDecoder().decode(Alert.self, from: Data($0.utf8)) }
        dismissAt = try row.optionalInteger("dismiss_at").map(Int.init)
        revision = Int(try row.integer("revision"))
        sentRevision = Int(try row.integer("sent_revision"))
        channel = try row.optionalString("channel")
        channelEnvironment = try row.optionalText("channel_environment", as: PushEnvironment.init(rawValue:))
        failures = Int(try row.integer("failures"))
        delivery = try row.text("delivery", as: DeliveryState.init(rawValue:))
        error = try row.optionalString("error")
        deviceState = try row.optionalText("device_state", as: ObservedState.init(rawValue:))
        createdAt = Int(try row.integer("created_at"))
        updatedAt = try row.optionalInteger("updated_at").map(Int.init)
        endedAt = try row.optionalInteger("ended_at").map(Int.init)
    }

    var status: ActivityStatus {
        status(layoutReadable: nil)
    }

    func status(layoutReadable: Bool?) -> ActivityStatus {
        let superseded = phase != .ended && revision > sentRevision && [.accepted, .failed, .unknown].contains(delivery)
        return ActivityStatus(name: name, id: id, title: title, state: phase, revision: revision, delivery: superseded ? .pending : delivery,
                              device: deviceState, error: superseded ? nil : error, layoutReadable: layoutReadable,
                              startedAt: Date(timeIntervalSince1970: Double(createdAt)), endedAt: endedAt.map { Date(timeIntervalSince1970: Double($0)) })
    }

    func fingerprint() throws -> String {
        try JSONDecoder().decode(LyktaActivity.ContentState.self, from: Data(content.utf8)).fingerprint
    }
}
