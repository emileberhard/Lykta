import Foundation
@testable import LyktaCore
import Testing
@testable import LyktaGateway

struct NotificationTests {
    let store: Store
    let push = FakePush()
    let api: API
    let credentials: Credentials
    let now = Int(Date().timeIntervalSince1970)

    init() async throws {
        store = try Store(path: ":memory:")
        api = API(store: store, maximumDevices: 2, maximumLiveActivities: 2, environments: [.development],
                  enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(9, 9, 9), shutdown: Shutdown())
        let registration = Registration(environment: .development, appVersion: "0.6.0 (1)", proof: .invite(try await store.invite(now: now)))
        credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                       body: Array(try JSONEncoder().encode(registration)))).decoded()
        try await report(Self.allowed)
    }

    static let allowed = NotificationSettings(authorization: .authorized, alertStyle: .banner, token: PushToken(hex: "0123abcd"))

    static let printer: JSONValue = [
        "sender": ["id": "printer", "name": "Printer"],
        "body": "Benchy finished in 42 min. Come get it!",
        "sound": .bool(true),
    ]

    @Test func repeatingARequestReturnsItsNotificationAndADifferentRequestConflicts() async throws {
        let created = try await send("PUT", "/v1/notifications/printer-job-42-done", body: Self.printer)
        #expect(created.status == 201)
        #expect(try created.decoded() as Notified == Notified(state: "queued", error: nil, banners: "temporary"))
        let reordered = #"{"sound": true, "body": "Benchy finished in 42 min. Come get it!", "sender": {"name": "Printer", "id": "printer"}}"#
        let repeated = await api.handle(HTTPRequest(method: "PUT", target: "/v1/notifications/printer-job-42-done",
                                                    headers: ["authorization": "Bearer \(credentials.agentToken)"], body: Array(reordered.utf8)))
        #expect(repeated.status == 200)
        let different = try await send("PUT", "/v1/notifications/printer-job-42-done", body: [
            "sender": ["id": "printer", "name": "Printer"], "body": "Benchy failed.",
        ])
        #expect(different.status == 409)
        #expect((try different.decoded() as Refusal).message.hasPrefix("Another notification already uses the name printer-job-42-done until "))
        try await deliver(at: now)
        #expect(push.sent == ["notify"])
    }

    @Test func aRepeatedRequestIsAnsweredBeforeTheLimitAndReadinessChecks() async throws {
        #expect(try await send("PUT", "/v1/notifications/done", body: Self.printer).status == 201)
        try await report(NotificationSettings(authorization: .denied, alertStyle: .banner, token: nil))
        #expect(try await send("PUT", "/v1/notifications/done", body: Self.printer).status == 200)
        #expect(try await send("PUT", "/v1/notifications/other", body: Self.printer).status == 409)
    }

    @Test(arguments: [
        (nil, "app_update_required"),
        (NotificationSettings(authorization: .notDetermined, alertStyle: .banner, token: nil), "notifications_not_set_up"),
        (NotificationSettings(authorization: .authorized, alertStyle: .banner, token: nil), "notifications_not_set_up"),
        (NotificationSettings(authorization: .denied, alertStyle: .banner, token: PushToken(hex: "0123abcd")), "notifications_not_allowed"),
    ] as [(NotificationSettings?, String)])
    func refusesPhonesThatCannotShowNotifications(_ settings: NotificationSettings?, error: String) async throws {
        let store = try Store(path: ":memory:")
        let api = API(store: store, maximumDevices: 1, maximumLiveActivities: 1, environments: [.development],
                      enrolment: Enrolment(appID: AppAttestTests.appID), version: nil, shutdown: Shutdown())
        let registration = Registration(environment: .development, appVersion: "0.5.4 (1)", proof: .invite(try await store.invite(now: now)))
        let credentials: Credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                                        body: Array(try JSONEncoder().encode(registration)))).decoded()
        var report: [String: JSONValue] = ["appVersion": "0.5.4 (1)", "bundleInstance": .string(UUID().uuidString), "activities": .array([])]
        report["notifications"] = try settings.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
        #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: JSONValue.object(report).json)).status == 200)
        let response = await api.handle(HTTPRequest(method: "PUT", target: "/v1/notifications/done",
                                                    headers: ["authorization": "Bearer \(credentials.agentToken)"], body: Self.printer.json))
        #expect(response.status == 409)
        #expect((try response.decoded() as Refusal).error == error)
    }

    @Test func limitsNotificationsPerHourAndSaysWhenToSendAgain() async throws {
        for index in 0..<Store.maximumNotificationsPerHour {
            #expect(try await send("PUT", "/v1/notifications/n\(index)", body: Self.printer).status == 201)
        }
        let refused = try await send("PUT", "/v1/notifications/one-more", body: Self.printer)
        #expect(refused.status == 429)
        #expect((try refused.decoded() as Refusal).error == "too_many_notifications")
        #expect(refused.headers["retry-after"].flatMap(Int.init).map { (3590...3600).contains($0) } == true)
    }

    @Test(arguments: [
        (["sender": ["id": "printer", "name": "Printer"], "body": "Done", "sound": .bool(false)],
         "sound must be true for the default sound; leave it out for a silent notification."),
        (["sender": ["id": "printer", "name": "Printer"], "body": "Done", "sound": .null],
         "sound must be true for the default sound; leave it out for a silent notification."),
        (["sender": ["id": "printer", "name": "Printer"], "body": "Done", "title": "Printer"],
         "Unknown key \"title\"; expected body, sender, sound."),
        (["sender": ["id": "printer", "name": "Printer", "avatar": "printer.png"], "body": "Done"],
         "Unknown key \"sender.avatar\"; expected id, name."),
        (["sender": ["id": "Printer", "name": "Printer"], "body": "Done"],
         "sender.id names the sender: 1 to 64 lowercase letters, digits, '-', '_' or '.', the same for every notification it sends."),
        (["sender": ["id": "printer", "name": "Printer"], "body": ""], "body must be 1 to 500 characters."),
    ] as [(JSONValue, String)])
    func refusesInvalidRequestsWithTheFix(_ body: JSONValue, message: String) async throws {
        let response = try await send("PUT", "/v1/notifications/done", body: body)
        #expect(response.status == 400)
        #expect(try response.decoded() as Refusal == Refusal(error: "invalid_request", message: message))
    }

    @Test func sendsACommunicationAlertThatExpiresWithTheNotification() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let created = try decoder.decode(Created.self, from: Data(try await send("PUT", "/v1/notifications/done", body: Self.printer).body))
        try await deliver(at: now)
        let alert = try #require(push.alerts.first)
        #expect(try alert.payload.value(at: "aps") == [
            "alert": ["title": "Printer", "body": "Benchy finished in 42 min. Come get it!"],
            "sound": "default", "mutable-content": .number(1), "thread-id": "printer",
        ])
        #expect(try alert.payload.value(at: "lykta.sender") == "printer")
        #expect(alert.expiration == Int(created.expires.timeIntervalSince1970))
        #expect(try await status("done") == Notified(state: "sent", error: nil, banners: "temporary"))
    }

    @Test func theExtensionsReportShowsWhatThePhonePreparedOnce() async throws {
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        try await deliver(at: now)
        let (id, token) = try fetchToken()
        #expect(await report(id, token: "lykta_fetch_wrong", ["style": "plain", "sound": "none"]).status == 401)
        #expect(await report(id, token: token, ["style": "communication", "avatar": "initials", "sound": "default"]).status == 204)
        #expect(await report(id, token: token, ["style": "plain", "sound": "none"]).status == 204)
        let detail: Prepared = try await send("GET", "/v1/notifications/done").decoded()
        #expect(detail.state == "received")
        #expect(detail.phone == ["style": "communication", "avatar": "initials", "sound": "default"])
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.filter { $0.name.hasPrefix("notification.") || $0.name == "push.notification" }.map(\.name)
            == ["notification.put", "push.notification", "notification.received"])
        #expect(!events.events.contains { String(describing: $0.detail).contains("Benchy") })
    }

    @Test func aReportBeforeApplesAnswerKeepsTheNotificationReceived() async throws {
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        let jobs = try await store.claim(now: now, limit: 4)
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        let attempt = try await delivery.send(try #require(jobs.first), now: now)
        let (id, token) = try fetchToken()
        #expect(await report(id, token: token, ["style": "communication", "avatar": "initials", "sound": "default"]).status == 204)
        try await store.finish(jobs[0], attempt, now: now)
        #expect(try await status("done").state == "received")
    }

    @Test func neverResendsANotificationWithAnUnknownOutcome() async throws {
        push.fail("notify", .unknown("timed out"))
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        try await deliver(at: now)
        try await deliver(at: now + 600)
        #expect(push.sent == ["notify"])
        #expect(try await status("done") == Notified(state: "unknown", error: "APNs outcome unknown: timed out", banners: "temporary"))
        let (id, token) = try fetchToken()
        #expect(await report(id, token: token, ["style": "communication", "avatar": "initials", "sound": "default"]).status == 204)
        #expect(try await status("done").state == "received")
    }

    @Test func aRestartWhileSendingLeavesTheNotificationUnknown() async throws {
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        _ = try await store.claim(now: now, limit: 4)
        try await store.recover()
        try await deliver(at: now + 600)
        #expect(push.sent.isEmpty)
        #expect(try await status("done") == Notified(state: "unknown", error: "The gateway restarted while sending this notification.", banners: "temporary"))
    }

    @Test func retriesRefusalsThatGuaranteeNoDeliveryWithANewFetchToken() async throws {
        push.fail("notify", .rejected(status: 503, reason: "ServiceUnavailable"))
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        try await deliver(at: now)
        #expect(try await status("done").state == "queued")
        try await deliver(at: now + 2)
        #expect(push.sent == ["notify", "notify"])
        #expect(try await status("done").state == "sent")
        let tokens = try push.alerts.map { try $0.payload.value(at: "lykta.token") }
        #expect(tokens.count == 2 && tokens[0] != tokens[1])
    }

    @Test func forgetsARejectedNotificationTokenAndFailsWhatWaitedForIt() async throws {
        push.fail("notify", .rejected(status: 410, reason: "Unregistered"))
        _ = try await send("PUT", "/v1/notifications/first", body: Self.printer)
        _ = try await send("PUT", "/v1/notifications/second", body: Self.printer)
        try await deliver(at: now, limit: 1)
        #expect(push.sent == ["notify"])
        #expect(try await status("first").state == "failed")
        #expect(try await status("second").state == "failed")
        #expect((try await send("PUT", "/v1/notifications/third", body: Self.printer).decoded() as Refusal).error == "notifications_not_set_up")
    }

    @Test func aNotificationAndItsNameLastADay() async throws {
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        let device = try #require(try await store.device(agentToken: credentials.agentToken))
        let later = now + Store.notificationLifetime
        await #expect(throws: APIError.self) { try await store.notification(device, name: Name(rawValue: "done")!, now: later) }
        let request = try NotificationRequest.decode(["sender": ["id": "printer", "name": "Printer"], "body": "Another day"])
        #expect(try await store.putNotification(device, name: Name(rawValue: "done")!, request: request, now: later).created)
    }

    @Test func aQueuedNotificationThatExpiresFails() async throws {
        push.fail("notify", .rejected(status: 503, reason: "ServiceUnavailable"))
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        try await deliver(at: now)
        try await deliver(at: now + Store.notificationLifetime)
        #expect(push.sent == ["notify"])
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.last?.name == "notification.expired")
    }

    private struct Notified: Decodable, Equatable {
        let state: String
        let error: String?
        let banners: String?
    }

    private struct Created: Decodable {
        let expires: Date
    }

    private struct Prepared: Decodable {
        let state: String
        let phone: JSONValue?
    }

    private func fetchToken() throws -> (UUID, String) {
        let alert = try #require(push.alerts.last)
        guard case let .string(id) = try alert.payload.value(at: "lykta.id"), let uuid = UUID(uuidString: id),
              case let .string(token) = try alert.payload.value(at: "lykta.token") else {
            throw LayoutError("the alert carries no notification id and token")
        }
        return (uuid, token)
    }

    private func report(_ settings: NotificationSettings) async throws {
        let report = DeviceReport(pushToStartToken: PushToken(hex: "abcdef"), appVersion: "0.6.0 (1)", layoutVersion: Layout.version,
                                  bundleInstance: UUID(), activities: [], notifications: settings)
        let response = await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                                    body: Array(try JSONEncoder().encode(report))))
        #expect(response.status == 200)
    }

    private func report(_ id: UUID, token: String, _ body: JSONValue) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: "POST", target: "/v1/device/notifications/\(id.uuidString)/report",
                                     headers: ["authorization": "Bearer \(token)"], body: body.json))
    }

    private func status(_ name: String) async throws -> Notified {
        try await send("GET", "/v1/notifications/\(name)").decoded()
    }

    private func send(_ method: String, _ target: String, body: JSONValue? = nil) async throws -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: target, headers: ["authorization": "Bearer \(credentials.agentToken)"],
                                     body: body?.json ?? []))
    }

    private func deliver(at time: Int, limit: Int = 4) async throws {
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        for job in try await store.claim(now: time, limit: limit) {
            try await store.finish(job, try await delivery.send(job, now: time), now: time)
        }
    }
}
