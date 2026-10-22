import Foundation
import LyktaCore
import Synchronization
import Testing
@testable import LyktaGateway

struct GatewayTests {
    let store: Store
    let push = FakePush()
    let api: API
    let credentials: Credentials
    let now = Int(Date().timeIntervalSince1970)
    let bundleInstance = UUID()

    init() async throws {
        store = try Store(path: ":memory:", maximumDevices: 2, maximumLiveActivities: 2)
        api = API(store: store, environments: [.development])
        credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                       body: Self.json(Registration(environment: .development, appVersion: "1.0 (1)"))))
            .decoded()
        _ = try await report([])
    }

    @Test func startsCoalescesUpdatesAndEnds() async throws {
        try await put("build", Self.start)
        try await deliver(at: now)
        try await put("build", ["data": ["step": "Test"]])
        try await put("build", ["data": ["step": "Sign"]])
        try await deliver(at: now + 1)
        let ended: Status = try await send("DELETE", "/v1/activities/build?dismissAfter=0").decoded()
        #expect(ended.state == "ending")
        try await deliver(at: now + 2)
        try await deliver(at: now + 302)
        #expect(push.sent == ["createChannel", "start", "update 5", "end 10 dismissed", "deleteChannel"])
        #expect(try await status("build") == Status(state: "ended", delivery: "accepted", error: nil))
    }

    @Test func endsAndRemovesAnActivityAtItsDeadline() async throws {
        guard case var .object(start) = Self.start else { return }
        start["endAfter"] = .number(60)
        try await put("build", .object(start))
        try await deliver(at: now)
        try await put("build", ["data": ["step": "Sign"]])
        try await deliver(at: now + 58)
        #expect(try await status("build").state == "live")
        try await deliver(at: now + 62)
        #expect(push.sent == ["createChannel", "start", "update 5", "end 10 dismissed"])
        #expect(try await status("build") == Status(state: "ended", delivery: "accepted", error: nil))
    }

    @Test func neverRetriesAnUnknownStart() async throws {
        push.fail("start", .unknown("timed out"))
        try await put("build", Self.start)
        try await deliver(at: now)
        try await deliver(at: now + 60)
        #expect(push.sent == ["createChannel", "start"])
        #expect(try await status("build") == Status(state: "live", delivery: "unknown", error: "APNs outcome unknown: timed out"))
    }

    @Test func retriesThrottledUpdatesWithTheirAlert() async throws {
        try await put("build", Self.start)
        try await deliver(at: now)
        push.fail("update", .rejected(status: 429, reason: "TooManyRequests"))
        try await put("build", ["alert": ["body": "Tests failed"]])
        try await deliver(at: now + 1)
        #expect(try await status("build").delivery == "throttled")
        try await deliver(at: now + 2)
        try await deliver(at: now + 3)
        #expect(push.sent == ["createChannel", "start", "update 10", "update 10"])
        #expect(try await status("build") == Status(state: "live", delivery: "accepted", error: nil))
    }

    @Test func forgetsARejectedPushToken() async throws {
        push.fail("start", .rejected(status: 400, reason: "BadDeviceToken"))
        try await put("build", Self.start)
        try await deliver(at: now)
        #expect(try await status("build") == Status(state: "ended", delivery: "failed", error: "APNs 400 BadDeviceToken"))
        let retry = try await send("PUT", "/v1/activities/build", body: Self.start)
        #expect(retry.status == 409)
        #expect(try retry.decoded() as Failure == Failure(error: "device_not_ready"))
    }

    @Test func endingBeforeDeliverySendsNothing() async throws {
        try await put("build", Self.start)
        _ = try await send("DELETE", "/v1/activities/build")
        try await deliver(at: now)
        #expect(push.sent.isEmpty)
        #expect(try await status("build").state == "ended")
    }

    @Test func tellsThePhoneToEndActivitiesTheGatewayEnded() async throws {
        let started: Identified = try await put("build", Self.start)
        try await deliver(at: now)
        _ = try await send("DELETE", "/v1/activities/build")
        try await deliver(at: now + 1)
        let result = try await report([.init(id: started.id, state: .active)])
        #expect(result.end == [started.id])
    }

    @Test(arguments: [
        Rejection(method: "PUT", target: "/v1/activities/build", body: ["title": "Build", "colour": "red"], status: 400, error: "invalid_request"),
        Rejection(method: "PUT", target: "/v1/activities/Build", body: GatewayTests.start, status: 400, error: "invalid_name"),
        Rejection(method: "PUT", target: "/v1/activities/build", body: ["title": "Build", "layout": ["lockScreen": "a"]], status: 400, error: "invalid_layout"),
        Rejection(method: "PUT", target: "/v1/activities/build", body: ["title": "Build", "layout": GatewayTests.oversized], status: 413, error: "payload_too_large"),
        Rejection(method: "PUT", target: "/v1/activities/build", body: ["endAfter": .number(28801)], status: 400, error: "invalid_request"),
        Rejection(method: "DELETE", target: "/v1/activities/build", body: [:], status: 404, error: "not_found"),
    ])
    func rejectsInvalidRequests(_ rejection: Rejection) async throws {
        let response = try await send(rejection.method, rejection.target, body: rejection.body)
        #expect(response.status == rejection.status)
        #expect(try response.decoded() as Failure == Failure(error: rejection.error))
    }

    @Test func recordsWhatTheGatewayAndThePhoneSaw() async throws {
        let started: Identified = try await put("build", Self.start)
        try await deliver(at: now)
        let observed = Event(id: UUID(), at: Date(), name: "activity.observed", activity: started.id, detail: ["state": "active"])
        let upload = EventBatch(events: [observed, observed])
        let uploaded = await api.handle(HTTPRequest(method: "POST", target: "/v1/device/events",
                                                    headers: ["authorization": "Bearer \(credentials.deviceSecret)"], body: Self.json(upload)))
        #expect(uploaded.status == 204)
        _ = try await send("PUT", "/v1/activities/Build", body: Self.start)
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.map(\.name) == ["device.registered", "device.sync", "activity.put", "push.start", "activity.observed", "request.failed"])
        let push = try #require(events.events.first { $0.name == "push.start" })
        #expect(push.source == "gateway")
        #expect(push.activity == started.id)
        #expect(push.detail["outcome"] == "accepted")
        #expect(push.detail["uniqueID"] != nil)
        #expect(events.events.first { $0.name == "activity.put" }?.detail["fingerprint"] == push.detail["fingerprint"])
        #expect(events.events.first { $0.name == "activity.observed" }?.source == "app")
    }

    @Test func togglesChangeTheDataAndPushIt() async throws {
        let started: Identified = try await put("list", Self.checklist)
        try await deliver(at: now)
        let tick = Action(id: UUID(), activity: started.id, input: .toggle("items.0.done", isOn: true))
        #expect(await act(tick).status == 204)
        #expect(await act(tick).status == 204)
        let detail: Detail = try await send("GET", "/v1/activities/list").decoded()
        #expect(detail.revision == 2)
        #expect(detail.data == ["items": .array([["name": "Milk", "done": .bool(true)]])])
        try await deliver(at: now + 1)
        #expect(push.sent == ["createChannel", "start", "update 5"])
        let stale = await act(Action(id: UUID(), activity: started.id, input: .toggle("items.1.done", isOn: true)))
        #expect(stale.status == 409)
    }

    @Test func buttonPressesReachTheAgentInOrder() async throws {
        let started: Identified = try await put("deploy", Self.question)
        let empty: Actions = try await send("GET", "/v1/actions").decoded()
        #expect(empty.actions.isEmpty)
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("retry"))).status == 204)
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("delete"))).status == 409)
        let pressed: Actions = try await send("GET", "/v1/actions?after=\(empty.cursor)&wait=1").decoded()
        #expect(pressed.actions.map(\.button) == ["retry"])
        #expect(pressed.actions.map(\.activity) == ["deploy"])
        let none: Actions = try await send("GET", "/v1/actions?after=\(pressed.cursor)").decoded()
        #expect(none.actions.isEmpty)
        #expect(none.cursor == pressed.cursor)
        try await store.housekeep(now: now + 86_401)
        let expired: Actions = try await send("GET", "/v1/actions?after=0").decoded()
        #expect(expired.actions.isEmpty)
    }

    @Test func ifRevisionRefusesToOverwriteANewerState() async throws {
        try await put("build", Self.start)
        try await put("build", ["data": ["step": "Test"], "ifRevision": .number(1)])
        let stale = try await send("PUT", "/v1/activities/build", body: ["data": ["step": "Sign"], "ifRevision": .number(1)])
        #expect(stale.status == 409)
        #expect(try stale.decoded() as Failure == Failure(error: "conflict"))
    }

    @Test func requiresTheAgentToken() async throws {
        let response = await api.handle(HTTPRequest(method: "GET", target: "/v1/activities",
                                                    headers: ["authorization": "Bearer \(credentials.deviceSecret)"], body: []))
        #expect(response.status == 401)
    }

    @Test func skillExamplesCompile() throws {
        let markdown = String(decoding: PackageResources.layout_md, as: UTF8.self)
        let blocks = markdown.components(separatedBy: "```json\n").dropFirst().map { $0.components(separatedBy: "\n```")[0] }
        let snippetData: JSONValue = [
            "steps": .array([["name": "Build"]]), "items": .array([["name": "Milk", "done": .bool(false)]]), "step": "Mix", "index": .number(1),
        ]
        #expect(blocks.count == 8)
        for block in blocks {
            guard case let .object(fields) = try JSONDecoder().decode(JSONValue.self, from: Data(block.utf8)) else {
                Issue.record("not an object: \(block)")
                continue
            }
            let layout: JSONValue = if let layout = fields["layout"] {
                try layout.filled(with: fields["data"] ?? .object([:]))
            } else {
                .object(["lockScreen": try JSONValue.object(fields).filled(with: snippetData), "compactLeading": "a", "compactTrailing": "b", "minimal": "c"])
            }
            _ = try Layout(json: layout.json)
        }
    }

    // MARK: Helpers

    static let start: JSONValue = [
        "title": "Build",
        "layout": ["lockScreen": "{{step}}", "compactLeading": "a", "compactTrailing": "b", "minimal": "c"],
        "data": ["step": "Compile"],
    ]

    static let checklist: JSONValue = [
        "title": "Shopping",
        "layout": [
            "lockScreen": ["vstack": .array([["each": "items", "as": "item", "do": ["toggle": "item.done", "label": "{{item.name}}"]]])],
            "compactLeading": "a", "compactTrailing": "b", "minimal": "c",
        ],
        "data": ["items": .array([["name": "Milk", "done": .bool(false)]])],
    ]

    static let question: JSONValue = [
        "title": "Deploy failed",
        "layout": [
            "lockScreen": ["hstack": .array([["button": "retry", "label": "Retry"], ["button": "stop", "label": "Stop"]])],
            "compactLeading": "a", "compactTrailing": "b", "minimal": "c",
        ],
    ]

    static let oversized: JSONValue = [
        "lockScreen": .object(["vstack": .array((0..<200).map { _ in .string(UUID().uuidString) })]),
        "compactLeading": "a", "compactTrailing": "b", "minimal": "c",
    ]

    @discardableResult
    private func put(_ name: String, _ body: JSONValue) async throws -> Identified {
        let response = try await send("PUT", "/v1/activities/\(name)", body: body)
        #expect(response.status == 200, "\(String(decoding: response.body, as: UTF8.self))")
        return try response.decoded()
    }

    private func status(_ name: String) async throws -> Status {
        try await send("GET", "/v1/activities/\(name)").decoded()
    }

    private func report(_ activities: [DeviceReport.Observed]) async throws -> SyncResult {
        let report = DeviceReport(pushToStartToken: PushToken(hex: "abcdef"), appVersion: "1.0 (1)", bundleInstance: bundleInstance,
                                  activities: activities)
        return try await api.handle(HTTPRequest(method: "PUT", target: "/v1/device",
                                                headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                                body: Self.json(report))).decoded()
    }

    private func send(_ method: String, _ target: String, body: JSONValue? = nil) async throws -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: target, headers: ["authorization": "Bearer \(credentials.agentToken)"],
                                     body: body?.json ?? []))
    }

    private func act(_ action: Action) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: "POST", target: "/v1/device/actions",
                                     headers: ["authorization": "Bearer \(credentials.deviceSecret)"], body: Self.json(action)))
    }

    private func deliver(at time: Int) async throws {
        let delivery = Delivery(store: store, push: push)
        for job in try await store.claim(now: time, limit: 4) {
            try await store.finish(job, try await delivery.send(job, now: time), now: time)
        }
    }

    private static func json(_ value: some Encodable) -> [UInt8] {
        Array(try! JSONEncoder().encode(value))
    }
}

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

struct Failure: Decodable, Equatable {
    let error: String
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
    let environments: Set<PushEnvironment> = [.development]

    private struct State {
        var sent: [String] = []
        var failures: [String: APNsError] = [:]
    }

    private let state = Mutex(State())

    var sent: [String] { state.withLock { $0.sent } }

    func fail(_ call: String, _ error: APNsError) {
        state.withLock { $0.failures[call] = error }
    }

    func start(_ payload: Data, deviceToken: PushToken, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        struct Sent: Decodable {
            struct APS: Decodable {
                struct Alert: Decodable { let title: String; let body: String }
                let alert: Alert
            }
            let aps: APS
        }
        let alert = try? JSONDecoder().decode(Sent.self, from: payload).aps.alert
        try record(alert.map { !$0.title.isEmpty && !$0.body.isEmpty } == true ? "start" : "start without an alert title and body")
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

    private func record(_ call: String, detail: String = "") throws(APNsError) {
        let failure = state.withLock { state in
            state.sent.append(call + detail)
            return state.failures.removeValue(forKey: call)
        }
        if let failure { throw failure }
    }
}
