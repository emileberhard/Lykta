import Foundation
import Testing
@testable import LyktaCore
@testable import LyktaGateway

struct DrawnAvatarTests {
    private let store: Store
    private let api: API
    private let credentials: Credentials
    private let push = FakePush()
    private let now = Int(Date().timeIntervalSince1970)

    init() async throws {
        store = try Store(path: ":memory:")
        api = API(store: store, maximumDevices: 1, maximumLiveActivities: 1, environments: [.development],
                  enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(9, 9, 9), shutdown: Shutdown())
        let registration = Registration(environment: .development, appVersion: "0.17.0", proof: .invite(try await store.invite(now: now)))
        credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                       body: Array(try JSONEncoder().encode(registration)))).decoded()
        try await report(version: Version(0, 17, 0))
    }

    @Test func thePushCarriesTheExpandedDrawingAndEventsCarryOnlyItsFingerprint() async throws {
        #expect(await send("PUT", "/v1/parts/clawd", "ET").status == 201)
        #expect(await send("PUT", "/v1/notifications/done", request(["use": "clawd"])).status == 201)
        try await deliver()
        let payload = try pushed()
        #expect(payload.avatar == nil)
        let drawing = try #require(payload.drawing)
        #expect(drawing.fingerprint == fingerprint(JSONValue.string("ET").json))
        guard case .text("ET") = try drawing.node(limit: Layout.maximumBytes).content else {
            Issue.record("Expected the saved shorthand to remain a drawing")
            return
        }
        let events: Events = try await send("GET", "/v1/events").decoded()
        let put = try #require(events.events.first { $0.name == "notification.put" })
        #expect(put.detail["avatar"] == "drawing")
        #expect(put.detail["avatarFingerprint"] == .string(fingerprint(JSONValue.string("ET").json)))
        #expect(put.detail["drawing"] == nil)
    }

    @Test func olderPhonesRefuseDrawingsAtTheAvatarBoundary() async throws {
        try await report(version: Version(0, 16, 2))
        let refused: Refusal = try await send("PUT", "/v1/notifications/done", request(["text": "ET"])).decoded()
        #expect(refused.error == "app_update_required")
        #expect(refused.message.hasPrefix("sender.avatar uses notification.avatar.node, which needs Lykta 0.17.0 or later"))
    }

    @Test(arguments: [
        (#"{"button":"go","label":"Go"}"#, "sender.avatar"),
        (#"{"toggle":"done","isOn":true,"label":"Done"}"#, "sender.avatar"),
        (#"{"link":"https://example.com","label":"Open"}"#, "sender.avatar"),
        (#"{"timer":[0,100]}"#, "sender.avatar"),
        (#"{"progress":[0,100]}"#, "sender.avatar"),
        (#"{"date":0,"style":"relative"}"#, "sender.avatar"),
        (#"{"date":0,"style":"offset"}"#, "sender.avatar"),
        (#"{"date":0,"style":"timer"}"#, "sender.avatar"),
        (#"{"if":"dark","then":"Dark","else":"Light"}"#, "sender.avatar.if"),
        (#"{"text":"{{name}}"}"#, "sender.avatar.text"),
        (#"{"vstack":[{"each":"items","as":"item","do":"{{item}}"}]}"#, "sender.avatar.vstack[0].each"),
        (#"{"text":"X","modifiers":[{"overlay":{"timer":[0,100]}}]}"#, "sender.avatar.modifiers[0].overlay"),
    ])
    func nonStillFamiliesAreRefusedWithTheirAuthoredPath(_ source: String, _ path: String) async throws {
        let node = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let response = await send("PUT", "/v1/notifications/done", request(node))
        #expect(response.status == 400)
        let refused: Refusal = try response.decoded()
        #expect(refused.error == "invalid_layout")
        #expect(refused.message.hasPrefix(path + ":"))
    }

    @Test func numericProgressAndAbsoluteDatesStayAllowed() async throws {
        let body: JSONValue = ["vstack": .array([["progress": .number(0.5)], ["date": .number(0), "style": "date"]])]
        #expect(await send("PUT", "/v1/notifications/done", request(body)).status == 201)
    }

    @Test func oversizedDrawingsNameTheAvatarAndItsCompressedBytes() async throws {
        var value: UInt64 = 7
        let text = String((0..<12_000).map { _ in
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return Character(UnicodeScalar(65 + UInt32(value >> 32) % 26)!)
        })
        let response = await send("PUT", "/v1/notifications/done", request(["text": .string(text)]))
        #expect(response.status == 413)
        let refused: Refusal = try response.decoded()
        #expect(refused.error == "payload_too_large")
        #expect(refused.message.contains("sender.avatar compresses to "))
    }

    @Test(arguments: [NotificationReport.Avatar.image, .initials])
    func oldReadersCanReadTheStoredDrawingRequestAndReport(_ avatar: NotificationReport.Avatar) async throws {
        #expect(await send("PUT", "/v1/notifications/done", request(["text": "ET"])).status == 201)
        let jobs = try await store.claim(now: now, limit: 1)
        guard case let .notification(job) = try #require(jobs.first) else {
            Issue.record("Expected the persisted notification")
            return
        }
        let raw = Data(job.request.canonical.utf8)
        let stored = try JSONDecoder().decode(JSONValue.self, from: raw)
        #expect(try stored.value(at: "sender.drawing") == ["text": "ET"])
        let old = try JSONDecoder().decode(Readers016.NotificationRequest.self, from: raw)
        #expect(old.sender.avatar == nil)
        #expect(old.body == "Finished")
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        try await store.finish(jobs[0], try await delivery.send(jobs[0], now: now), now: now)
        let payload = try pushed()
        #expect(await receive(payload, avatar: avatar, failure: avatar == .initials ? .render : nil).status == 204)
        let status: JSONValue = try await send("GET", "/v1/notifications/done").decoded()
        let phone = try status.value(at: "phone")
        let report = try JSONDecoder().decode(Readers016.NotificationReport.self, from: Data(phone.json))
        #expect(report.style == .communication(Readers016.NotificationReport.Avatar(rawValue: avatar.rawValue)!))
        #expect(try phone.value(at: "avatar") == .string(avatar.rawValue))
        #expect(throws: LayoutError.self) { try phone.value(at: "avatarFailure") }
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.first { $0.name == "notification.received" }?.detail["avatarFailure"] == (avatar == .initials ? "render" : nil))
    }

    @Test(arguments: ["replace", "delete"])
    func retriesCompareTheExpandedCanonicalDrawing(_ change: String) async throws {
        _ = await send("PUT", "/v1/parts/clawd", "Original")
        #expect(await send("PUT", "/v1/notifications/done", request(["use": "clawd"])).status == 201)
        #expect(await send("PUT", "/v1/notifications/done", request(["use": "clawd"])).status == 200)
        if change == "replace" { _ = await send("PUT", "/v1/parts/clawd", "Replaced") }
        else { _ = await send("DELETE", "/v1/parts/clawd") }
        let refused: Refusal = try await send("PUT", "/v1/notifications/done", request(["use": "clawd"])).decoded()
        #expect(refused.error == (change == "replace" ? "conflict" : "invalid_layout"))
        if change == "delete" { #expect(refused.message.contains("unknown part")) }
        try await deliver()
        guard case .text("Original") = try #require(pushed().drawing).node(limit: Layout.maximumBytes).content else {
            Issue.record("The queued notification must keep its drawing")
            return
        }
    }

    @Test(arguments: PackedNode.Failure.allCases)
    func reportFailuresUseOnlyTheEventAndKeepTheOldReportShape(_ failure: PackedNode.Failure) async throws {
        _ = await send("PUT", "/v1/notifications/done", request(["text": "ET"]))
        try await deliver()
        let payload = try pushed()
        #expect(await receive(payload, avatar: .initials, failure: failure).status == 204)
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.first { $0.name == "notification.received" }?.detail["avatarFailure"] == .string(failure.rawValue))
    }

    private func request(_ avatar: JSONValue) -> JSONValue {
        ["sender": ["id": "claude", "name": "Claude", "avatar": avatar], "body": "Finished"]
    }

    private func send(_ method: String, _ target: String, _ body: JSONValue? = nil) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: target, headers: ["authorization": "Bearer \(credentials.agentToken)"], body: body?.json ?? []))
    }

    private func report(version: Version) async throws {
        let report = DeviceReport(pushToStartToken: nil, appVersion: version.description, layoutVersion: version, bundleInstance: UUID(), activities: [],
                                  notifications: .init(authorization: .authorized, alertStyle: .banner, registration: .registered(PushToken(Data([1])))))
        #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: Array(try JSONEncoder().encode(report)))).status == 200)
    }

    private func deliver() async throws {
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        for job in try await store.claim(now: now, limit: 1) {
            try await store.finish(job, try await delivery.send(job, now: now), now: now)
        }
    }

    private func pushed() throws -> NotificationPayload {
        try JSONDecoder().decode(NotificationPayload.self, from: Data(try #require(push.alerts.last).payload.value(at: "lykta").json))
    }

    private func receive(_ payload: NotificationPayload, avatar: NotificationReport.Avatar, failure: PackedNode.Failure?) async -> HTTPResponse {
        let body: JSONValue = ["style": "communication", "avatar": .string(avatar.rawValue), "sound": "none"]
        let query = failure.map { "?avatarFailure=\($0.rawValue)" } ?? ""
        return await api.handle(HTTPRequest(method: "POST", target: "/v1/device/notifications/\(payload.id)/report\(query)",
                                            headers: ["authorization": "Bearer \(payload.token)"], body: body.json))
    }
}
