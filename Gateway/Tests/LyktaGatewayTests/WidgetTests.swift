import Foundation
import LyktaCore
import Synchronization
import Testing
@testable import LyktaGateway

struct WidgetTests {
    let store: Store
    let push = FakePush()
    let api: API
    let credentials: Credentials
    let token: String
    let now = Int(Date().timeIntervalSince1970)
    private let reports = Reports()

    init() async throws {
        store = try Store(path: ":memory:")
        api = API(store: store, maximumDevices: 2, maximumLiveActivities: 2, environments: [.development],
                  enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(0, 12, 0), shutdown: Shutdown())
        let registration = Registration(environment: .development, appVersion: Layout.version.description, proof: .invite(try await store.invite(now: now)))
        credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:], body: Array(try JSONEncoder().encode(registration)))).decoded()
        let response = await api.handle(HTTPRequest(method: "POST", target: "/v1/device/widgets/credential", headers: ["authorization": "Bearer \(credentials.deviceSecret)"], body: []))
        token = (try response.decoded() as WidgetCredential).widgetToken
    }

    private static let request: JSONValue = ["title": "Steps", "layout": ["systemSmall": ["text": "{{steps}}"]], "data": ["steps": "10"], "staleAfter": .number(60)]

    private struct Status: Decodable {
        struct Fetch: Decodable { let revision: Int; let at: String }
        let id: UUID
        let revision: Int
        let delivery: String
        let nextPush: String?
        let error: String?
        let placed: [WidgetLayout.Family]
        let fetched: Fetch?
        let layout: JSONValue?
        let data: JSONValue?
    }

    @Test func createsUpdatesDeletesAndRecreationGetsANewIdentity() async throws {
        let created = await send("PUT", "/v1/widgets/steps", Self.request)
        #expect(created.status == 201)
        let first: Status = try created.decoded()
        #expect(first.revision == 1)
        let repeated: Status = try await send("PUT", "/v1/widgets/steps", ["data": ["steps": "10"]]).decoded()
        #expect(repeated.revision == 1)
        let updated: Status = try await send("PUT", "/v1/widgets/steps", ["data": ["steps": "20"], "ifRevision": .number(1)]).decoded()
        #expect(updated.revision == 2)
        #expect(updated.id == first.id)
        let detail: Status = try await send("GET", "/v1/widgets/steps").decoded()
        #expect(detail.data == ["steps": "20"])
        #expect(detail.layout == ["systemSmall": ["text": "{{steps}}"]])
        #expect(await send("DELETE", "/v1/widgets/steps").status == 204)
        #expect(await send("GET", "/v1/widgets/steps").status == 404)
        #expect(await fetch(first.id).status == 410)
        let replacement: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        #expect(replacement.id != first.id)
    }

    @Test func derivesEveryDeliveryStateFromPlacesPushesAndFetchReceipts() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        #expect(created.delivery == "failed")
        #expect(created.error?.contains("widget push token") == true)
        try await report([])
        #expect(try await status().delivery == "notPlaced")
        try await report([created.id])
        #expect(try await status().delivery == "pending")
        try await deliver(now)
        #expect(try await status().delivery == "accepted")
        #expect(await fetch(created.id).status == 200)
        let fetched = try await status()
        #expect(fetched.delivery == "fetched")
        #expect(fetched.fetched?.revision == 1)
        #expect(fetched.placed == [.systemSmall])
        try await report([created.id])
        #expect(try await status().delivery == "fetched")
        _ = await send("PUT", "/v1/widgets/steps", ["data": ["steps": "30"]])
        push.fail("widgets", .rejected(status: 403, reason: "Forbidden"))
        try await deliver(now + Store.widgetPushInterval)
        #expect(try await status().delivery == "failed")
        #expect(try await status().error == "APNs 403 Forbidden")
    }

    @Test func coalescesRevisionsAndWaitsTwentyMinutesBeforeTheNextPush() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await report([created.id])
        _ = await send("PUT", "/v1/widgets/steps", ["data": ["steps": "20"]])
        _ = await send("PUT", "/v1/widgets/steps", ["data": ["steps": "30"]])
        try await deliver(now)
        #expect(push.sent == ["widgets"])
        _ = await send("PUT", "/v1/widgets/steps", ["data": ["steps": "40"]])
        try await deliver(now + Store.widgetPushInterval - 1)
        #expect(push.sent == ["widgets"])
        #expect(try await status().delivery == "pending")
        #expect(try await status().nextPush != nil)
        try await deliver(now + Store.widgetPushInterval)
        #expect(push.sent == ["widgets", "widgets"])
        let snapshot: WidgetSnapshot = try await fetch(created.id).decoded()
        #expect(snapshot.revision == 4)
        #expect(snapshot.content == .layout(["systemSmall": ["text": "40"]]))
    }

    @Test func fetchReturnsFullContentUnchangedOrRequiresAndRecordsOnlyDrawnRevisions() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        let full: WidgetSnapshot = try await fetch(created.id).decoded()
        #expect(full.title == "Steps")
        #expect(full.content == .layout(["systemSmall": ["text": "10"]]))
        #expect(full.staleAt != nil)
        #expect(await fetch(created.id, have: 1).status == 204)
        _ = await send("PUT", "/v1/widgets/steps", ["data": ["steps": "20"]])
        let old = await fetch(created.id, have: 1, layout: "0.11.0")
        #expect(old.status == 200)
        #expect((try old.decoded() as WidgetSnapshot).content == .requires(Version(0, 12, 0)))
        let unreadable = try await status()
        #expect(unreadable.fetched?.revision == 1)
        #expect(unreadable.delivery == "failed")
        #expect(unreadable.error?.hasPrefix("This widget needs Lykta 0.12.0 or later, and this phone's Lykta app draws layouts up to 0.11.0.") == true)
        let medium = await send("GET", "/v1/device/widgets/\(created.id)?family=systemMedium&layout=\(Layout.version)", token: token)
        #expect(medium.status == 200)
        #expect(try await status().fetched?.revision == 1)
        #expect(await send("GET", "/v1/device/widgets/\(created.id)?family=unknown&layout=0.12.0", token: token).status == 400)
        #expect(await send("GET", "/v1/device/widgets/\(created.id)?family=systemSmall", token: token).status == 400)
    }

    @Test func anUncertainPushCountsAgainstTheInterval() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await report([created.id])
        push.fail("widgets", .unknown("timed out"))
        try await deliver(now)
        #expect(try await status().delivery == "pending")
        _ = await send("PUT", "/v1/widgets/steps", ["data": ["steps": "20"]])
        try await deliver(now + Store.widgetPushInterval - 1)
        #expect(push.sent == ["widgets"])
        try await deliver(now + Store.widgetPushInterval)
        #expect(push.sent == ["widgets", "widgets"])
        #expect(try await status().delivery == "accepted")
    }

    @Test func ignoresAReportOlderThanTheLastOne() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        let stale = WidgetReport(sequence: reports.next(), pushToken: nil, layoutVersion: Layout.version, places: [])
        try await report([created.id])
        let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stale))
        #expect(await send("PUT", "/v1/device/widgets", body, token: token).status == 204)
        #expect(try await status().placed == [.systemSmall])
    }

    @Test func onlyChangesToPlacedWidgetsPush() async throws {
        try await report([])
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await deliver(now)
        #expect(push.sent.isEmpty)
        try await report([created.id])
        try await deliver(now)
        #expect(push.sent.isEmpty)
        let placed = try await status()
        #expect(placed.delivery == "pending")
        #expect(placed.nextPush == nil)
        #expect(await send("DELETE", "/v1/widgets/steps").status == 204)
        try await deliver(now)
        #expect(push.sent == ["widgets"])
        let gone: Failure = try await fetch(created.id).decoded()
        #expect(gone.error == "widget_deleted")
    }

    @Test func admitsAgainstThePhonesLatestLayoutVersionAndKeepsThePushTokenWhenOmitted() async throws {
        let oldReport = DeviceReport(pushToStartToken: nil, appVersion: "0.11.0", layoutVersion: Version(0, 11, 0),
                                     bundleInstance: UUID(), activities: [], notifications: NotificationSettings(authorization: .denied, alertStyle: .banner, registration: .pending))
        let old = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(oldReport))
        #expect(await send("PUT", "/v1/device", old, token: credentials.deviceSecret).status == 200)
        let refused = await send("PUT", "/v1/widgets/steps", Self.request)
        #expect(refused.status == 409)
        #expect((try refused.decoded() as Failure).error == "app_update_required")
        try await report([])
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        #expect(await send("PUT", "/v1/device", old, token: credentials.deviceSecret).status == 200)
        #expect(await send("PUT", "/v1/widgets/steps", ["title": "Downgraded"]).status == 409)
        let placesOnly: JSONValue = ["sequence": .number(Double(reports.next())), "layoutVersion": .string(Layout.version.description),
                                     "places": .array([["widget": .string(created.id.uuidString), "family": "systemSmall"]])]
        #expect(await send("PUT", "/v1/device/widgets", placesOnly, token: token).status == 204)
        #expect(await send("PUT", "/v1/widgets/steps", ["data": ["steps": "12"]]).status == 200)
        try await deliver(now)
        #expect(push.sent == ["widgets"])
    }

    @Test func widgetCredentialsReadOnlyTheirOwnPhone() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        let registration = Registration(environment: .development, appVersion: Layout.version.description, proof: .invite(try await store.invite(now: now)))
        let other: Credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                                 body: Array(try JSONEncoder().encode(registration)))).decoded()
        let otherCredential: WidgetCredential = try await send("POST", "/v1/device/widgets/credential", token: other.deviceSecret).decoded()
        let response = await send("GET", "/v1/device/widgets/\(created.id)?family=systemSmall&layout=0.12.0", token: otherCredential.widgetToken)
        #expect(response.status == 410)
        #expect((try response.decoded() as Failure).error == "widget_deleted")
        let report: JSONValue = ["sequence": .number(1), "layoutVersion": .string(Layout.version.description), "places": .array([["widget": .string(created.id.uuidString), "family": "systemSmall"]])]
        #expect(await send("PUT", "/v1/device/widgets", report, token: otherCredential.widgetToken).status == 204)
        #expect(try await status().placed.isEmpty)
    }

    @Test func credentialRotationAndResetInvalidateWidgetAccess() async throws {
        _ = await send("PUT", "/v1/widgets/steps", Self.request)
        #expect(await send("GET", "/v1/device/widgets", token: token).status == 200)
        let rotation: WidgetCredential = try await send("POST", "/v1/device/widgets/credential", token: credentials.deviceSecret).decoded()
        #expect(rotation.widgetToken != token)
        #expect(await send("GET", "/v1/device/widgets", token: token).status == 401)
        #expect(await send("GET", "/v1/device/widgets", token: rotation.widgetToken).status == 200)
        #expect(await send("DELETE", "/v1/device", token: credentials.deviceSecret).status == 204)
        #expect(await send("GET", "/v1/device/widgets", token: rotation.widgetToken).status == 401)
    }

    @Test(arguments: ["/v1/widgets", "/v1/activities", "/v1/events", "/v1/device/widgets/credential"])
    func widgetCredentialsCannotUseOtherRoutes(_ route: String) async {
        #expect(await send(route.hasSuffix("credential") ? "POST" : "GET", route, token: token).status == 401)
    }

    @Test(arguments: ["agent", "device"])
    func widgetRoutesRequireTheirOwnCredential(_ kind: String) async {
        let wrong = kind == "agent" ? credentials.agentToken : credentials.deviceSecret
        #expect(await send("GET", "/v1/device/widgets", token: wrong).status == 401)
        #expect(await send("PUT", "/v1/device/widgets", token: wrong).status == 401)
    }

    @Test func enforcesTheLimitAndRevisionPreconditions() async throws {
        for index in 0..<32 { #expect(await send("PUT", "/v1/widgets/w\(index)", Self.request).status == 201) }
        let excess = await send("PUT", "/v1/widgets/excess", Self.request)
        #expect(excess.status == 409)
        #expect((try excess.decoded() as Failure).error == "too_many_widgets")
        #expect(await send("PUT", "/v1/widgets/w0", ["title": "Updated", "ifRevision": .number(1)]).status == 200)
        #expect(await send("PUT", "/v1/widgets/w0", ["title": "Stale", "ifRevision": .number(1)]).status == 409)
        #expect(await send("PUT", "/v1/widgets/missing", ["ifRevision": .number(1)]).status == 409)
        #expect(await send("DELETE", "/v1/widgets/w1").status == 204)
        #expect(await send("PUT", "/v1/widgets/excess", Self.request).status == 201)
    }

    @Test(arguments: ["alert", "endAfter", "dismissAfter", "relevance"])
    func rejectsActivityFieldsAtTheirJSONPath(_ key: String) async throws {
        let response = await send("PUT", "/v1/widgets/steps", .object([key: .number(1)]))
        #expect(response.status == 400)
        let refusal: Refusal = try response.decoded()
        #expect(refusal.error == "invalid_request")
        #expect(refusal.message.hasPrefix(key + ":"))
    }

    @Test func expandsPartsAndNowBeforeAdmission() async throws {
        let response = await send("PUT", "/v1/widgets/steps", ["title": "Timer", "layout": ["parts": ["timer": ["text": "{{ends}}"]], "systemSmall": ["use": "timer"]], "now": ["ends": .number(60)]])
        #expect(response.status == 201)
        let created: Status = try response.decoded()
        #expect(created.layout == ["systemSmall": ["text": "{{ends}}"]])
        let data = try #require(created.data)
        guard case let .number(ends) = try data.value(at: "ends") else { Issue.record("now must write a number"); return }
        #expect(ends >= Double(now + 60))
    }

    @Test(arguments: [APNsError.notSent("connection refused"), .rejected(status: 429, reason: "TooManyRequests"), .rejected(status: 503, reason: "ServiceUnavailable")])
    func retriesInvalidationsAndMovesBadTokensOnlyOnce(_ failure: APNsError) async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await report([created.id])
        push.fail("widgets", failure)
        try await deliver(now)
        #expect(try await status().delivery == "pending")
        try await deliver(now + 1)
        #expect(push.sent == ["widgets"])
        push.acceptTokens(in: [.production])
        try await deliver(now + 2)
        try await deliver(now + 2)
        #expect(try await status().delivery == "accepted")
        _ = await send("PUT", "/v1/widgets/steps", ["title": "New"])
        push.acceptTokens(in: [])
        try await deliver(now + 2 + Store.widgetPushInterval)
        #expect(try await status().delivery == "failed")
    }

    @Test func replacingAnInFlightPushTokenDoesNotFailItsReplacement() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await report([created.id])
        let job = try #require(await store.claim(now: now, limit: 4).first)
        let report: JSONValue = ["sequence": .number(Double(reports.next())),
                                 "pushToken": .string(String(repeating: "ab", count: 32)), "layoutVersion": .string(Layout.version.description),
                                 "places": .array([["widget": .string(created.id.uuidString), "family": "systemSmall"]])]
        #expect(await send("PUT", "/v1/device/widgets", report, token: token).status == 204)
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        push.fail("widgets", .rejected(status: 403, reason: "Forbidden"))
        try await store.finish(job, try await delivery.send(job, now: now), now: now)
        #expect(try await status().delivery == "pending")
        try await deliver(now)
        #expect(try await status().delivery == "accepted")
    }

    @Test func aPushInterruptedByARestartOrAReplacedTokenStillWaitsTheInterval() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await report([created.id])
        _ = try #require(await store.claim(now: now, limit: 4).first)
        try await store.recover(now: now)
        try await deliver(now + 1)
        #expect(push.sent.isEmpty)
        let job = try #require(await store.claim(now: now + Store.widgetPushInterval, limit: 4).first)
        let replaced: JSONValue = ["sequence": .number(Double(reports.next())), "pushToken": .string(String(repeating: "ab", count: 32)),
                                   "layoutVersion": .string(Layout.version.description),
                                   "places": .array([["widget": .string(created.id.uuidString), "family": "systemSmall"]])]
        #expect(await send("PUT", "/v1/device/widgets", replaced, token: token).status == 204)
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        try await store.finish(job, try await delivery.send(job, now: now + Store.widgetPushInterval), now: now + Store.widgetPushInterval)
        try await deliver(now + Store.widgetPushInterval + 1)
        #expect(push.sent == ["widgets"])
    }

    @Test func aWaitingPutFinishesWhenTheExtensionFetchesTheRevision() async throws {
        let created: Status = try await send("PUT", "/v1/widgets/steps", Self.request).decoded()
        try await report([created.id])
        async let response = send("PUT", "/v1/widgets/steps?wait=5", ["data": ["steps": "20"]])
        while try await status().revision < 2 { await Task.yield() }
        try await deliver(now)
        _ = await fetch(created.id)
        let result: Status = try await response.decoded()
        #expect(result.delivery == "fetched")
    }

    @Test func everyBundledWidgetExampleCanBePut() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/LyktaGateway/Skill/examples/widgets")
        let examples = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        for example in examples {
            let body = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: example))
            #expect(await send("PUT", "/v1/widgets/\(example.deletingPathExtension().lastPathComponent)", body).status == 201)
        }
    }

    private func send(_ method: String, _ target: String, _ body: JSONValue? = nil, token: String? = nil) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: target, headers: ["authorization": "Bearer \(token ?? credentials.agentToken)"], body: body?.json ?? []))
    }

    private func fetch(_ id: UUID, have: Int? = nil, layout: String = Layout.version.description) async -> HTTPResponse {
        await send("GET", "/v1/device/widgets/\(id)?family=systemSmall&layout=\(layout)" + (have.map { "&have=\($0)" } ?? ""), token: token)
    }

    private func status() async throws -> Status { try await send("GET", "/v1/widgets/steps").decoded() }

    private func report(_ ids: [UUID]) async throws {
        let report = WidgetReport(sequence: reports.next(), pushToken: PushToken(Data(repeating: 9, count: 32)), layoutVersion: Layout.version,
                                  places: ids.map { WidgetPlace(widget: $0, family: .systemSmall) })
        let body = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(report))
        #expect(await send("PUT", "/v1/device/widgets", body, token: token).status == 204)
    }

    private func deliver(_ time: Int) async throws {
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        for job in try await store.claim(now: time, limit: 4) { try await store.finish(job, try await delivery.send(job, now: time), now: time) }
    }
}

private final class Reports: Sendable {
    private let count = Mutex<Int64>(0)

    func next() -> Int64 {
        count.withLock { $0 += 1; return $0 }
    }
}
