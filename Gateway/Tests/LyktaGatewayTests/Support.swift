import Foundation
import LyktaCore
import Synchronization
import Testing
@testable import LyktaGateway

struct Rejection: Sendable, CustomTestStringConvertible {
    let method: String, target: String, body: JSONValue, status: Int, error: String

    var testDescription: String { "\(method) \(target) → \(error)" }
}

struct Status: Decodable, Equatable {
    let state: String
    let delivery: String
    let error: String?
}

struct Detail: Decodable {
    let revision: Int
    let data: JSONValue
}

struct Actions: Decodable {
    struct Entry: Decodable {
        let activity: String
        let button: String?
    }

    let actions: [Entry]
    let cursor: Int
}

struct Events: Decodable {
    struct Entry: Decodable {
        let name: String
        let source: String
        let activity: UUID?
        let detail: [String: JSONValue]
    }

    let events: [Entry]
}

struct Identified: Decodable {
    let id: UUID
}

struct Admitted: Decodable {
    let payloadBytes: Int
}

struct Failure: Decodable, Equatable {
    let error: String
}

struct Refusal: Decodable, Equatable {
    let error: String
    let message: String
}

struct Readability: Decodable, Equatable {
    let layoutReadable: Bool?
}

extension HTTPResponse {
    func decoded<T: Decodable>() throws -> T {
        try JSONDecoder().decode(T.self, from: Data(body))
    }
}

extension JSONValue: @retroactive ExpressibleByStringLiteral, @retroactive ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

final class FakePush: PushService {
    let environments: Set<PushEnvironment> = [.development, .production]

    private struct State {
        var sent: [String] = []
        var failures: [String: APNsError] = [:]
        var alerts: [(payload: JSONValue, expiration: Int)] = []
        var startAlerts: [String] = []
        var tokenEnvironments: Set<PushEnvironment> = [.development]
    }

    private let state = Mutex(State())

    var sent: [String] { state.withLock { $0.sent } }

    var alerts: [(payload: JSONValue, expiration: Int)] { state.withLock { $0.alerts } }

    var startAlerts: [String] { state.withLock { $0.startAlerts } }

    func fail(_ call: String, _ error: APNsError) {
        state.withLock { $0.failures[call] = error }
    }

    func acceptTokens(in environments: Set<PushEnvironment>) {
        state.withLock { $0.tokenEnvironments = environments }
    }

    func start(_ payload: Data, deviceToken: PushToken, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        struct Sent: Decodable {
            struct APS: Decodable {
                struct Alert: Decodable { let title: String; let body: String }
                let alert: Alert
            }
            let aps: APS
        }
        try Self.check(payload)
        let alert = try? JSONDecoder().decode(Sent.self, from: payload).aps.alert
        state.withLock { $0.startAlerts.append(alert?.body ?? "") }
        try record(alert.map { !$0.title.isEmpty && !$0.body.isEmpty } == true ? "start" : "start without an alert title and body", to: environment)
        return "unique-\(id)"
    }

    func notify(_ payload: Data, deviceToken: PushToken, expiration: Int, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        state.withLock { $0.alerts.append(((try? JSONDecoder().decode(JSONValue.self, from: payload)) ?? .null, expiration)) }
        try record("notify", to: environment)
        return "unique-\(id)"
    }

    func broadcast(_ payload: Data, channel: String, priority: Int, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        struct Sent: Decodable {
            struct APS: Decodable {
                let event: String
                let timestamp: Int
                let dismissal: Int?

                enum CodingKeys: String, CodingKey {
                    case event, timestamp, dismissal = "dismissal-date"
                }
            }
            let aps: APS
        }
        try Self.check(payload)
        let aps = try? JSONDecoder().decode(Sent.self, from: payload).aps
        let dismissed = aps.flatMap { aps in aps.dismissal.map { $0 <= aps.timestamp } } == true
        try record(aps?.event ?? "malformed", detail: " \(priority)" + (dismissed ? " dismissed" : ""))
        return nil
    }

    func createChannel(environment: PushEnvironment) async throws(APNsError) -> String {
        try record("createChannel")
        return UUID().uuidString
    }

    func deleteChannel(_ channel: String, environment: PushEnvironment) async throws(APNsError) {
        try record("deleteChannel")
    }

    func channels(environment: PushEnvironment) async throws(APNsError) -> [String] {
        []
    }

    private static func check(_ payload: Data) throws(APNsError) {
        if payload.count > 4096 { throw .rejected(status: 413, reason: "PayloadTooLarge") }
    }

    private func record(_ call: String, detail: String = "", to environment: PushEnvironment? = nil) throws(APNsError) {
        let failure = state.withLock { state -> APNsError? in
            state.sent.append(call + detail)
            if let environment, !state.tokenEnvironments.contains(environment) { return APNsError.rejected(status: 400, reason: "BadDeviceToken") }
            return state.failures.removeValue(forKey: call)
        }
        if let failure { throw failure }
    }
}
