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
        try await self.init(path: ":memory:")
    }

    private init(path: String) async throws {
        store = try Store(path: path)
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
        guard case .text("ET") = try drawing.node().content else {
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
        (#"{"button":"go","label":"Go"}"#, "sender.avatar", "controls and links need interaction, and an avatar is drawn once; use a fixed node"),
        (#"{"toggle":"done","isOn":true,"label":"Done"}"#, "sender.avatar", "controls and links need interaction, and an avatar is drawn once; use a fixed node"),
        (#"{"link":"https://example.com","label":"Open"}"#, "sender.avatar", "controls and links need interaction, and an avatar is drawn once; use a fixed node"),
        (#"{"timer":[0,100]}"#, "sender.avatar", "timers and interval progress change with time, and an avatar is drawn once; use a fixed value"),
        (#"{"progress":[0,100]}"#, "sender.avatar", "timers and interval progress change with time, and an avatar is drawn once; use a fixed value"),
        (#"{"date":0,"style":"relative"}"#, "sender.avatar", "relative dates change with time, and an avatar is drawn once; use a fixed date or time"),
        (#"{"date":0,"style":"offset"}"#, "sender.avatar", "relative dates change with time, and an avatar is drawn once; use a fixed date or time"),
        (#"{"date":0,"style":"timer"}"#, "sender.avatar", "relative dates change with time, and an avatar is drawn once; use a fixed date or time"),
        (#"{"if":"dark","then":"Dark","else":"Light"}"#, "sender.avatar.if", "environment conditions change after arrival, and an avatar is drawn once; use a fixed condition"),
        (#"{"text":"{{name}}"}"#, "sender.avatar.text", "an avatar has no data; replace the placeholder with a fixed value"),
        (#"{"vstack":[{"each":"items","as":"item","do":"{{item}}"}]}"#, "sender.avatar.vstack[0].each", "an avatar has no data; use a fixed node"),
        (#"{"text":"X","modifiers":[{"overlay":{"timer":[0,100]}}]}"#, "sender.avatar.modifiers[0].overlay", "timers and interval progress change with time, and an avatar is drawn once; use a fixed value"),
        (#"{"vstack":["Hi",{"button":"go","label":"Go"}]}"#, "sender.avatar.vstack[1]", "controls and links need interaction, and an avatar is drawn once; use a fixed node"),
        (#"{"progress":2}"#, "sender.avatar.progress", "expected a value within 0...1"),
        (#"{"progress":0.5}"#, "sender.avatar.progress", "a linear bar draws as a placeholder in an avatar image; use style circular"),
        (#"{"gauge":0.5,"style":"linearCapacity"}"#, "sender.avatar.gauge", "a linearCapacity gauge draws as a placeholder in an avatar image; use style linear, circular or circularCapacity"),
        (#"{"accessoryBackground":true}"#, "sender.avatar.accessoryBackground", "accessoryBackground works only in accessoryCircular and accessoryRectangular"),
        (#"{"text":"X","modifiers":[{"privacySensitive":true}]}"#, "sender.avatar.modifiers[0].privacySensitive", "privacySensitive works only in a widget's presentations"),
    ], [false, true])
    func nonStillFamiliesAreRefusedWithTheirAuthoredPath(_ input: (String, String, String), _ saved: Bool) async throws {
        let (source, path, reason) = input
        let node = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        if saved { #expect(await send("PUT", "/v1/parts/with-button", node).status == 201) }
        let response = await send("PUT", "/v1/notifications/done", request(saved ? ["use": "with-button"] : node))
        #expect(response.status == 400)
        let refused: Refusal = try response.decoded()
        #expect(refused.error == "invalid_layout")
        let authored = saved ? path.replacingOccurrences(of: "sender.avatar", with: "parts/with-button") : path
        #expect(refused.message == authored + ": " + reason + (saved ? " (used at sender.avatar)" : ""))
    }

    @Test(arguments: [
        (#"{"use":"clwad"}"#, #"sender.avatar: unknown part "clwad"; saved parts: clawd"#),
        (#"{"use":"clawd","bogus":1}"#, #"sender.avatar: expected {"use": "name"} with optional modifiers"#),
        (#"{"parts":{},"text":"ET"}"#, "sender.avatar: a node cannot define parts; save each part separately"),
    ])
    func avatarExpansionErrorsNameTheAvatar(_ source: String, _ expected: String) async throws {
        _ = await send("PUT", "/v1/parts/clawd", "ET")
        let node = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let refused: Refusal = try await send("PUT", "/v1/notifications/done", request(node)).decoded()
        #expect(refused.error == "invalid_layout")
        #expect(refused.message == expected)
    }

    @Test func numericProgressAndAbsoluteDatesStayAllowed() async throws {
        let body: JSONValue = ["vstack": .array([["progress": .number(0.5), "style": "circular"], ["date": .number(0), "style": "date"]])]
        #expect(await send("PUT", "/v1/notifications/done", request(body)).status == 201)
    }

    @Test(arguments: ["linear", "circular", "circularCapacity"])
    func gaugesThatRenderAsImagesStayAllowed(_ style: String) async throws {
        let node: JSONValue = ["gauge": .number(0.5), "style": .string(style), "label": "Build"]
        #expect(await send("PUT", "/v1/notifications/done", request(node)).status == 201)
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
    func oldReadersCanReadThePersistedDrawingRequestAndReport(_ avatar: NotificationReport.Avatar) async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sqlite").path()
        defer { Self.removeDatabase(at: path) }
        let phone = try await Self(path: path)
        #expect(await phone.send("PUT", "/v1/notifications/done", phone.request(["text": "ET"])).status == 201)
        let database = try Database(path: path)
        let raw = Data(try #require(database.query("SELECT request FROM notifications").first).string("request").utf8)
        let stored = try JSONDecoder().decode(JSONValue.self, from: raw)
        #expect(try stored.value(at: "sender.drawing") == ["text": "ET"])
        let old = try JSONDecoder().decode(Readers016.NotificationRequest.self, from: raw)
        #expect(old.sender.avatar == nil)
        #expect(old.body == "Finished")
        try await phone.deliver()
        let payload = try phone.pushed()
        #expect(await phone.receive(payload, avatar: avatar, failure: avatar == .initials ? "render" : nil).status == 204)
        let rawReport = Data(try #require(database.query("SELECT phone FROM notifications").first).string("phone").utf8)
        let report = try JSONDecoder().decode(Readers016.NotificationReport.self, from: rawReport)
        #expect(report.style == .communication(Readers016.NotificationReport.Avatar(rawValue: avatar.rawValue)!))
        let events: Events = try await phone.send("GET", "/v1/events").decoded()
        #expect(events.events.first { $0.name == "notification.received" }?.detail["avatarFailure"] == (avatar == .initials ? "render" : nil))
    }

    @Test func deliveryPacksPersistedDrawingsWithoutDecodingThemAgain() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sqlite").path()
        defer { Self.removeDatabase(at: path) }
        let phone = try await Self(path: path)
        #expect(await phone.send("PUT", "/v1/notifications/done", phone.request(["text": "ET"])).status == 201)
        let futureNode: JSONValue = ["futureAvatarNode": "supported by the writer"]
        #expect(throws: LayoutError.self) { try futureNode.avatarNode() }
        let database = try Database(path: path)
        let stored: JSONValue = ["sender": ["id": "claude", "name": "Claude", "drawing": futureNode], "body": "Finished"]
        try database.run("UPDATE notifications SET request = ?", String(decoding: stored.json, as: UTF8.self))
        try await phone.deliver()
        let payload = try phone.pushed()
        let drawing = try #require(payload.drawing)
        #expect(try JSONEncoder().encode(drawing) == JSONEncoder().encode(PackedNode(packing: futureNode)))
        let status: JSONValue = try await phone.send("GET", "/v1/notifications/done").decoded()
        #expect(try status.value(at: "state") == "sent")
    }

    private static func removeDatabase(at path: String) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
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
        guard case .text("Original") = try #require(pushed().drawing).node().content else {
            Issue.record("The queued notification must keep its drawing")
            return
        }
    }

    @Test(arguments: ["frame", "inflate", "decode", "deadline", "render"])
    func avatarFailureWireNamesAreRecordedLiterally(_ failure: String) async throws {
        _ = await send("PUT", "/v1/notifications/done", request(["text": "ET"]))
        try await deliver()
        let payload = try pushed()
        #expect(await receive(payload, avatar: .initials, failure: failure).status == 204)
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.first { $0.name == "notification.received" }?.detail["avatarFailure"] == .string(failure))
    }

    @Test(arguments: [("deadline", Optional("deadline")), ("memory", nil)])
    func diagnosticQueriesNeverDiscardAReport(_ supplied: String, _ recorded: String?) async throws {
        _ = await send("PUT", "/v1/notifications/done", request(["text": "ET"]))
        try await deliver()
        let payload = try pushed()
        #expect(await receive(payload, avatar: .initials, failure: supplied).status == 204)
        let status: JSONValue = try await send("GET", "/v1/notifications/done").decoded()
        #expect(try status.value(at: "state") == "received")
        #expect(try status.value(at: "phone") == ["style": "communication", "avatar": "initials", "sound": "none"])
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.first { $0.name == "notification.received" }?.detail["avatarFailure"] == recorded.map(JSONValue.string))
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

    private func receive(_ payload: NotificationPayload, avatar: NotificationReport.Avatar, failure: String?) async -> HTTPResponse {
        let body: JSONValue = ["style": "communication", "avatar": .string(avatar.rawValue), "sound": "none"]
        let query = failure.map { "?avatarFailure=\($0)" } ?? ""
        return await api.handle(HTTPRequest(method: "POST", target: "/v1/device/notifications/\(payload.id)/report\(query)",
                                            headers: ["authorization": "Bearer \(payload.token)"], body: body.json))
    }
}
