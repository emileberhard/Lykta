import Foundation
import LyktaCore

struct APIError: Error, Sendable {
    let status: Int
    let code: String
    let message: String
}

struct Device: Sendable {
    let id: String
    let environment: PushEnvironment
    let pushToken: String?
}

struct Alert: Codable, Equatable, Sendable {
    let title: String?
    let body: String
    let sound: Bool?
}

struct ActivityStatus: Encodable, Sendable {
    let name: String
    let id: String
    let title: String
    let state: String
    let delivery: String
    let device: String?
    let error: String?
    let startedAt: Date
    let endedAt: Date?
}

struct Activity: Sendable {
    enum Phase: String, Sendable {
        case starting, live, ending, ended
    }

    let id: String
    let name: String
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
    let delivery: String
    let error: String?
    let deviceState: String?
    let createdAt: Int
    let endedAt: Int?

    init(_ row: Row) throws {
        id = try row.string("id")
        name = try row.string("name")
        phase = Phase(rawValue: try row.string("phase"))!
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
        delivery = try row.string("delivery")
        error = try row.optionalString("error")
        deviceState = try row.optionalString("device_state")
        createdAt = Int(try row.integer("created_at"))
        endedAt = try row.optionalInteger("ended_at").map(Int.init)
    }

    var status: ActivityStatus {
        ActivityStatus(name: name, id: id, title: title, state: phase.rawValue, delivery: delivery, device: deviceState,
                       error: error, startedAt: Date(timeIntervalSince1970: Double(createdAt)),
                       endedAt: endedAt.map { Date(timeIntervalSince1970: Double($0)) })
    }

    func payload(_ event: String, now: Int, channel: String? = nil, alert: Alert? = nil) throws -> Data {
        var aps = Payload.APS(timestamp: now, event: event,
                              contentState: try JSONDecoder().decode(LyktaActivity.ContentState.self, from: Data(content.utf8)))
        if event == "start" {
            aps.attributesType = "LyktaActivity"
            aps.attributes = LyktaActivity(id: UUID(uuidString: id)!, name: name)
            aps.inputPushChannel = channel
        }
        if let alert = alert ?? (event == "start" ? Alert(title: nil, body: "", sound: nil) : nil) {
            aps.alert = Payload.Alert(title: alert.title ?? title, body: alert.body.isEmpty ? nil : alert.body,
                                      sound: alert.sound == true ? "default" : nil)
        }
        if event != "end" { aps.staleDate = staleAfter.map { now + $0 } }
        aps.relevanceScore = relevance
        aps.dismissalDate = event == "end" ? dismissAt : nil
        return try JSONEncoder().encode(Payload(aps: aps))
    }
}

struct Payload: Encodable {
    struct Alert: Encodable {
        let title: String
        let body: String?
        let sound: String?
    }

    struct APS: Encodable {
        let timestamp: Int
        let event: String
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
