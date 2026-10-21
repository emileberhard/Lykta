import Foundation
import LyktaCore

struct APIError: Error, Encodable, Sendable {
    enum Code: String, Encodable, Sendable {
        case invalidRequest = "invalid_request"
        case invalidName = "invalid_name"
        case invalidLayout = "invalid_layout"
        case unsupportedEnvironment = "unsupported_environment"
        case unauthorized
        case registrationClosed = "registration_closed"
        case notFound = "not_found"
        case deviceNotReady = "device_not_ready"
        case tooManyActivities = "too_many_activities"
        case payloadTooLarge = "payload_too_large"
        case `internal`

        var status: Int {
            switch self {
            case .invalidRequest, .invalidName, .invalidLayout, .unsupportedEnvironment: 400
            case .unauthorized: 401
            case .registrationClosed: 403
            case .notFound: 404
            case .deviceNotReady, .tooManyActivities: 409
            case .payloadTooLarge: 413
            case .internal: 500
            }
        }
    }

    let code: Code
    let message: String

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code = "error", message
    }
}

struct ActivityName: RawRepresentable, Hashable, Sendable, Encodable, CustomStringConvertible {
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

struct Device: Sendable {
    let id: UUID
    let environment: PushEnvironment
    let pushToken: PushToken?
}

struct Alert: Codable, Equatable, Sendable {
    let title: String?
    let body: String
    let sound: Bool?
}

struct ActivityStatus: Encodable, Sendable {
    let name: ActivityName
    let id: UUID
    let title: String
    let state: Activity.Phase
    let delivery: DeliveryState
    let device: ObservedState?
    let error: String?
    let startedAt: Date
    let endedAt: Date?

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(name, forKey: .name)
        try fields.encode(id, forKey: .id)
        try fields.encode(title, forKey: .title)
        try fields.encode(state, forKey: .state)
        try fields.encode(delivery, forKey: .delivery)
        try fields.encode(device, forKey: .device)
        try fields.encode(error, forKey: .error)
        try fields.encode(startedAt, forKey: .startedAt)
        try fields.encode(endedAt, forKey: .endedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case name, id, title, state, delivery, device, error, startedAt, endedAt
    }
}

struct Activity: Sendable {
    enum Phase: String, Encodable, Sendable {
        case starting, live, ending, ended
    }

    let id: UUID
    let deviceID: UUID
    let name: ActivityName
    let phase: Phase
    let title: String
    let layout: String
    let data: String
    let content: String
    let staleAfter: Int?
    let relevance: Double?
    let alert: Alert?
    let dismissAt: Int?
    let revision: Int
    let channel: String?
    let failures: Int
    let delivery: DeliveryState
    let error: String?
    let deviceState: ObservedState?
    let createdAt: Int
    let endedAt: Int?

    init(_ row: Row) throws {
        id = try row.text("id", as: UUID.init(uuidString:))
        deviceID = try row.text("device_id", as: UUID.init(uuidString:))
        name = try row.text("name", as: ActivityName.init(rawValue:))
        phase = try row.text("phase", as: Phase.init(rawValue:))
        title = try row.string("title")
        layout = try row.string("layout")
        data = try row.string("data")
        content = try row.string("content")
        staleAfter = try row.optionalInteger("stale_after").map(Int.init)
        relevance = try row.optionalReal("relevance")
        alert = try row.optionalString("alert").map { try JSONDecoder().decode(Alert.self, from: Data($0.utf8)) }
        dismissAt = try row.optionalInteger("dismiss_at").map(Int.init)
        revision = Int(try row.integer("revision"))
        channel = try row.optionalString("channel")
        failures = Int(try row.integer("failures"))
        delivery = try row.text("delivery", as: DeliveryState.init(rawValue:))
        error = try row.optionalString("error")
        deviceState = try row.optionalText("device_state", as: ObservedState.init(rawValue:))
        createdAt = Int(try row.integer("created_at"))
        endedAt = try row.optionalInteger("ended_at").map(Int.init)
    }

    var status: ActivityStatus {
        ActivityStatus(name: name, id: id, title: title, state: phase, delivery: delivery, device: deviceState,
                       error: error, startedAt: Date(timeIntervalSince1970: Double(createdAt)),
                       endedAt: endedAt.map { Date(timeIntervalSince1970: Double($0)) })
    }

    func fingerprint() throws -> String {
        try JSONDecoder().decode(LyktaActivity.ContentState.self, from: Data(content.utf8)).fingerprint
    }

    func payload(_ event: Payload.Event, now: Int, channel: String? = nil, alert: Alert? = nil) throws -> Data {
        var aps = Payload.APS(timestamp: now, event: event,
                              contentState: try JSONDecoder().decode(LyktaActivity.ContentState.self, from: Data(content.utf8)))
        if event == .start {
            aps.attributesType = "LyktaActivity"
            aps.attributes = LyktaActivity(id: id, name: name.rawValue)
            aps.inputPushChannel = channel
        }
        if let alert = alert ?? (event == .start ? Alert(title: nil, body: "Live Activity started", sound: nil) : nil) {
            aps.alert = Payload.Alert(title: alert.title ?? title, body: alert.body,
                                      sound: alert.sound == true ? "default" : nil)
        }
        if event != .end { aps.staleDate = staleAfter.map { now + $0 } }
        aps.relevanceScore = relevance
        aps.dismissalDate = event == .end ? dismissAt : nil
        return try JSONEncoder().encode(Payload(aps: aps))
    }
}

struct Payload: Encodable {
    enum Event: String, Encodable {
        case start, update, end
    }

    struct Alert: Encodable {
        let title: String
        let body: String
        let sound: String?
    }

    struct APS: Encodable {
        let timestamp: Int
        let event: Event
        let contentState: LyktaActivity.ContentState
        var attributesType: String?
        var attributes: LyktaActivity?
        var inputPushChannel: String?
        var alert: Alert?
        var staleDate: Int?
        var dismissalDate: Int?
        var relevanceScore: Double?

        enum CodingKeys: String, CodingKey {
            case timestamp, event, attributes, alert
            case contentState = "content-state", attributesType = "attributes-type", inputPushChannel = "input-push-channel"
            case staleDate = "stale-date", dismissalDate = "dismissal-date", relevanceScore = "relevance-score"
        }
    }

    let aps: APS
}
