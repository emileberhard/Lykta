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

    static let allowed = NotificationSettings(authorization: .authorized, alertStyle: .banner, registration: .registered(PushToken(Data([0x01, 0x23, 0xab, 0xcd]))))

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

    @Test func aWaitingPutAnswersWithApplesOutcome() async throws {
        async let sent = send("PUT", "/v1/notifications/done?wait=5", body: Self.printer)
        try await deliverOnceClaimable(store, push, at: now)
        let response = try await sent
        #expect(response.status == 201)
        #expect(try response.decoded() as Notified == Notified(state: "sent", error: nil, banners: "temporary"))
    }

    @Test func aRepeatedRequestIsAnsweredBeforeTheLimitAndReadinessChecks() async throws {
        #expect(try await send("PUT", "/v1/notifications/done", body: Self.printer).status == 201)
        try await report(NotificationSettings(authorization: .denied, alertStyle: .banner, registration: .pending))
        #expect(try await send("PUT", "/v1/notifications/done", body: Self.printer).status == 200)
        #expect(try await send("PUT", "/v1/notifications/other", body: Self.printer).status == 409)
    }

    @Test(arguments: [
        (nil, "app_update_required"),
        (NotificationSettings(authorization: .notDetermined, alertStyle: .banner, registration: .pending), "notifications_not_set_up"),
        (NotificationSettings(authorization: .authorized, alertStyle: .banner, registration: .pending), "notifications_not_set_up"),
        (NotificationSettings(authorization: .denied, alertStyle: .banner, registration: .registered(PushToken(Data([0x01])))), "notifications_not_allowed"),
    ] as [(NotificationSettings?, String)])
    func refusesPhonesThatCannotShowNotifications(_ settings: NotificationSettings?, error: String) async throws {
        let phone = try await Phone(now: now)
        try await phone.report(settings)
        let response = await phone.notify()
        #expect(response.status == 409)
        #expect((try response.decoded() as Refusal).error == error)
    }

    @Test func saysWhyIOSRefusedTheTokenUntilThePhoneGetsOne() async throws {
        let refusal = "no valid “aps-environment” entitlement string found for application"
        let phone = try await Phone(now: now)
        try await phone.report(NotificationSettings(authorization: .authorized, alertStyle: .alert, registration: .failed(refusal)))
        let refused = await phone.notify()
        #expect(refused.status == 409)
        #expect(try refused.decoded() as Refusal == Refusal(error: "notifications_not_set_up", message: "iOS refused Lykta a notification token on "
            + "this phone (“\(refusal)”). Ask the user to update Lykta, or use a Live Activity."))
        let events: Events = try await phone.api.handle(HTTPRequest(method: "GET", target: "/v1/events",
                                                                    headers: ["authorization": "Bearer \(phone.credentials.agentToken)"], body: [])).decoded()
        let synced = try #require(events.events.last { $0.name == "device.sync" }?.detail["notifications"])
        #expect(try synced.value(at: "registrationError") == .string(refusal))
        try await phone.report(NotificationSettings(authorization: .authorized, alertStyle: .alert, registration: .registered(PushToken(Data([0x01])))))
        #expect(await phone.notify().status == 201)
    }

    @Test func aPhoneBackOnAnAppWithoutNotificationsGetsNoneUntilItUpdates() async throws {
        #expect(try await send("PUT", "/v1/notifications/queued", body: Self.printer).status == 201)
        let older: JSONValue = ["appVersion": "0.5.4 (1)", "bundleInstance": .string(UUID().uuidString), "activities": .array([])]
        #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: older.json)).status == 200)
        let response = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        #expect(response.status == 409)
        #expect((try response.decoded() as Refusal).error == "app_update_required")
        try await deliver(at: now)
        #expect(push.sent.isEmpty)
    }

    @Test func limitsNotificationsPerHourAndSaysWhenToSendAgain() async throws {
        for index in 0..<Store.maximumNotificationsPerHour {
            #expect(try await send("PUT", "/v1/notifications/n\(index)", body: Self.printer).status == 201)
        }
        let refused = try await send("PUT", "/v1/notifications/one-more", body: Self.printer)
        #expect(refused.status == 429)
        #expect((try refused.decoded() as Refusal).error == "too_many_notifications")
        #expect(refused.headers["retry-after"].flatMap(Int.init).map { (3590...3600).contains($0) } == true)
        #expect(try await send("PUT", "/v1/notifications/n0", body: Self.printer).status == 200)
    }

    @Test func refusesAPushThatWouldNotFitApplesLimit() async throws {
        let response = try await send("PUT", "/v1/notifications/family", body: [
            "sender": ["id": "family", "name": "Family"], "body": .string(String(repeating: "👩‍👩‍👧‍👦", count: 500)),
        ])
        #expect(response.status == 413)
        #expect((try response.decoded() as Refusal).error == "payload_too_large")
    }

    @Test(arguments: [
        (["sender": ["id": "printer", "name": "Printer"], "body": "Done", "sound": .bool(false)],
         "sound must be true for the default sound or the id of a sound from POST /v1/media; leave it out for silence."),
        (["sender": ["id": "printer", "name": "Printer"], "body": "Done", "sound": "chime.wav"],
         "sound must be true for the default sound or the id of a sound from POST /v1/media; leave it out for silence."),
        (["sender": ["id": "printer", "name": "Printer"], "body": "Done", "title": "Printer"],
         "Unknown key \"title\"; expected body, image, sender, sound."),
        (["sender": ["id": "printer", "name": "Printer", "color": "red"], "body": "Done"],
         "Unknown key \"sender.color\"; expected avatar, id, name."),
        (["sender": ["id": "printer", "name": "Printer", "avatar": "printer.png"], "body": "Done"],
         "sender.avatar must be the id of an image from POST /v1/media, such as m_0123456789abcdef0123456789abcdef. For a drawn avatar, send a node object such as {\"text\":\"ET\"}."),
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

    @Test func aFetchTokenOpensOnlyItsOwnNotification() async throws {
        _ = try await send("PUT", "/v1/notifications/first", body: Self.printer)
        _ = try await send("PUT", "/v1/notifications/second", body: Self.printer)
        try await deliver(at: now)
        let tokens = try fetchTokens()
        #expect(await report(tokens[0].id, token: tokens[1].token, ["style": "plain", "sound": "none"]).status == 401)
        #expect(try await status("first").state == "sent")
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

    @Test func anEarlyReportKeepsTheDeliverySlotUntilAppleAnswers() async throws {
        _ = try await send("PUT", "/v1/notifications/first", body: Self.printer)
        _ = try await send("PUT", "/v1/notifications/second", body: Self.printer)
        let first = try await store.claim(now: now, limit: 1)
        let attempt = try await Delivery(store: store, push: push, shutdown: Shutdown()).send(try #require(first.first), now: now)
        let (id, token) = try fetchToken()
        #expect(await report(id, token: token, ["style": "communication", "avatar": "initials", "sound": "default"]).status == 204)
        #expect(try await store.claim(now: now, limit: 1).isEmpty)
        try await store.finish(first[0], attempt, now: now)
        #expect(try await store.claim(now: now, limit: 1).count == 1)
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
        try await store.recover(now: now)
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

    @Test func backsOffAtMostFiveMinutesThroughALongOutage() async throws {
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        var time = now
        for _ in 0..<70 {
            push.fail("notify", .rejected(status: 503, reason: "ServiceUnavailable"))
            try await deliver(at: time)
            try await deliver(at: time + 1)
            time += 300
        }
        #expect(push.sent.count == 70)
    }

    @Test func keepsATokenThePhoneReplacedWhileTheOldOneWasRejected() async throws {
        push.fail("notify", .rejected(status: 410, reason: "Unregistered"))
        _ = try await send("PUT", "/v1/notifications/first", body: Self.printer)
        let jobs = try await store.claim(now: now, limit: 4)
        let attempt = try await Delivery(store: store, push: push, shutdown: Shutdown()).send(try #require(jobs.first), now: now)
        try await report(NotificationSettings(authorization: .authorized, alertStyle: .banner, registration: .registered(PushToken(Data([0x45, 0x67, 0xcd, 0xef])))))
        _ = try await send("PUT", "/v1/notifications/second", body: Self.printer)
        try await store.finish(jobs[0], attempt, now: now)
        try await deliver(at: now)
        #expect(try await status("first").state == "failed")
        #expect(try await status("second").state == "sent")
    }

    @Test func forgetsARejectedNotificationTokenAndFailsWhatWaitedForIt() async throws {
        push.fail("notify", .rejected(status: 410, reason: "Unregistered"))
        _ = try await send("PUT", "/v1/notifications/first", body: Self.printer)
        _ = try await send("PUT", "/v1/notifications/second", body: Self.printer)
        try await deliver(at: now, limit: 1)
        #expect(push.sent == ["notify"])
        #expect(try await status("first").state == "failed")
        #expect(try await status("second").state == "failed")
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.contains { $0.name == "notification.failed" && $0.detail["name"] == "second" })
        #expect((try await send("PUT", "/v1/notifications/third", body: Self.printer).decoded() as Refusal).error == "notifications_not_set_up")
    }

    @Test func sendsToTheEnvironmentThatAcceptsTheTokenUntilThePhoneHasANewOne() async throws {
        push.acceptTokens(in: [.production])
        _ = try await send("PUT", "/v1/notifications/first", body: Self.printer)
        try await deliver(at: now)
        try await deliver(at: now)
        _ = try await send("PUT", "/v1/notifications/second", body: Self.printer)
        try await deliver(at: now)
        try await report(NotificationSettings(authorization: .authorized, alertStyle: .banner, registration: .registered(PushToken(Data([0x45, 0x67, 0xcd, 0xef])))))
        push.acceptTokens(in: [.development])
        _ = try await send("PUT", "/v1/notifications/third", body: Self.printer)
        try await deliver(at: now)
        for name in ["first", "second", "third"] { #expect(try await status(name).state == "sent") }
        let events: Events = try await send("GET", "/v1/events").decoded()
        let pushes = events.events.filter { $0.name == "push.notification" }.map { [$0.detail["environment"], $0.detail["outcome"]] }
        #expect(pushes == [["development", "wrongEnvironment"], ["production", "accepted"], ["production", "accepted"], ["development", "accepted"]])
    }

    @Test func aNotificationAndItsNameLastADay() async throws {
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        let device = try #require(try await store.device(agentToken: credentials.agentToken))
        let later = now + Store.notificationLifetime
        await #expect(throws: APIError.self) { try await store.notification(device, name: Name(rawValue: "done")!, now: later) }
        let request = try NotificationRequest.decode(["sender": ["id": "printer", "name": "Printer"], "body": "Another day"])
        #expect(try await store.putNotification(device, name: Name(rawValue: "done")!, request: request, now: later))
    }

    @Test func aQueuedNotificationThatExpiresFails() async throws {
        push.fail("notify", .rejected(status: 503, reason: "ServiceUnavailable"))
        _ = try await send("PUT", "/v1/notifications/done", body: Self.printer)
        try await deliver(at: now)
        try await store.housekeep(now: now + Store.notificationLifetime)
        try await deliver(at: now + Store.notificationLifetime)
        #expect(push.sent == ["notify"])
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.last?.name == "notification.expired")
    }

    @Test func uploadsAFileOnceAndAnswersARepeatWithTheSameId() async throws {
        let sound = Self.wav(milliseconds: 4200)
        let created = await upload(sound)
        #expect(created.status == 201)
        let medium: Uploaded = try created.decoded()
        #expect(medium.type == "sound" && medium.durationSeconds == 4.2)
        let repeated = await upload(sound)
        #expect(repeated.status == 200)
        #expect(try repeated.decoded() == medium)
        #expect(try await upload(Self.png(width: 256, height: 256)).decoded() as Uploaded != medium)
    }

    @Test(arguments: [
        (wav(milliseconds: 31_000), "The sound is 31.0 s long; use a clip shorter than 30 s."),
        (wav(milliseconds: 1000, format: 3),
         "The WAV uses audio format 3 rather than linear PCM (1); convert it, such as with `ffmpeg -i in.wav -c:a pcm_s16le out.wav`."),
        (Array(wav(milliseconds: 1000).dropLast(100)), "The WAV's audio data is cut off; send the whole file."),
        (wav(milliseconds: 31_000, declaredByteRate: 32_000), "The WAV file is damaged or incomplete; export it again."),
        (png(width: 5000, height: 10), "The image is 5000×10 pixels; use at most 4096 on each side."),
        (jpeg(width: 640, height: 4097), "The image is 640×4097 pixels; use at most 4096 on each side."),
        (Array(png(width: 64, height: 64).prefix(16)), "The PNG file is damaged or incomplete; export it again."),
        (Array("ID3".utf8) + [UInt8](repeating: 0, count: 64),
         "The file is not a WAV, PNG or JPEG. Convert sounds to WAV with linear PCM, such as `ffmpeg -i in.m4a -ac 1 -c:a pcm_s16le out.wav`, "
         + "and images to PNG or JPEG."),
    ] as [([UInt8], String)])
    func refusesMediaThePhoneCannotUseWithTheFix(_ bytes: [UInt8], message: String) async throws {
        let response = await upload(bytes)
        #expect(response.status == 415)
        #expect(try response.decoded() as Refusal == Refusal(error: "unsupported_media", message: message))
    }

    @Test func keepsAtMost32MiBOfMediaPerPhoneUntilADayAfterTheirLastUse() async throws {
        for fill in 0..<8 {
            #expect(await upload(Self.wav(milliseconds: 21_000, sampleRate: 96_000, fill: UInt8(fill))).status == 201)
        }
        let refused = await upload(Self.wav(milliseconds: 21_000, sampleRate: 96_000, fill: 8))
        #expect(refused.status == 413)
        #expect((try refused.decoded() as Refusal).message.hasPrefix("This phone's media would take 34.6 MiB; the gateway keeps at most 32 MiB per phone"))
        let device = try #require(try await store.device(agentToken: credentials.agentToken))
        let later = now + Store.mediaRetention + 5
        #expect(try await store.putMedium(device, bytes: Self.wav(milliseconds: 21_000, sampleRate: 96_000, fill: 8), now: later).created)
    }

    @Test func aNotificationCarriesItsMediaAndItsFetchTokenOpensOnlyThose() async throws {
        let avatar: Uploaded = try await upload(Self.png(width: 256, height: 256)).decoded()
        let sound: Uploaded = try await upload(Self.wav(milliseconds: 2000)).decoded()
        let photo = Self.jpeg(width: 1200, height: 900)
        let image: Uploaded = try await upload(photo).decoded()
        let other: Uploaded = try await upload(Self.png(width: 64, height: 64)).decoded()
        let created = try await send("PUT", "/v1/notifications/done", body: [
            "sender": ["id": "printer", "name": "Printer", "avatar": .string(avatar.id)], "body": "Benchy finished.",
            "sound": .string(sound.id), "image": .string(image.id),
        ])
        #expect(created.status == 201)
        try await deliver(at: now)
        let alert = try #require(push.alerts.first)
        #expect(try alert.payload.value(at: "aps.sound") == "default")
        #expect(try alert.payload.value(at: "lykta.avatar") == .string(avatar.id))
        #expect(try alert.payload.value(at: "lykta.sound") == .string(sound.id))
        #expect(try alert.payload.value(at: "lykta.image") == .string(image.id))
        let (id, token) = try fetchToken()
        let fetched = await medium(id, image.id, token: token)
        #expect(fetched.status == 200 && fetched.contentType == "image/jpeg" && fetched.body == photo)
        #expect(await medium(id, other.id, token: token).status == 404)
        #expect(await medium(id, image.id, token: "lykta_fetch_other").status == 401)
        let events: Events = try await send("GET", "/v1/events").decoded()
        #expect(events.events.last?.name == "notification.media")
    }

    @Test func refusesReferencesToMediaThePhoneDoesNotHave() async throws {
        let avatar: Uploaded = try await upload(Self.png(width: 256, height: 256)).decoded()
        let wrongKind = try await send("PUT", "/v1/notifications/done", body: [
            "sender": ["id": "printer", "name": "Printer"], "body": "Done", "sound": .string(avatar.id),
        ])
        #expect(wrongKind.status == 400)
        #expect((try wrongKind.decoded() as Refusal).message == "sound must be a sound; \(avatar.id) is an image.")
        let unknown = "m_0123456789abcdef0123456789abcdef"
        let missing = try await send("PUT", "/v1/notifications/done", body: [
            "sender": ["id": "printer", "name": "Printer", "avatar": .string(unknown)], "body": "Done",
        ])
        #expect(missing.status == 400)
        #expect((try missing.decoded() as Refusal).message == "sender.avatar is \(unknown), which this phone has not uploaded or the gateway "
                + "removed a day after its last use. Upload the file with POST /v1/media and use the id it returns.")
    }

    @Test func mediaBelongToThePhoneThatUploadedThem() async throws {
        let registration = Registration(environment: .development, appVersion: "0.6.0 (1)", proof: .invite(try await store.invite(now: now)))
        let other: Credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                                  body: Array(try JSONEncoder().encode(registration)))).decoded()
        let uploaded: Uploaded = try await api.handle(HTTPRequest(method: "POST", target: "/v1/media",
                                                                  headers: ["authorization": "Bearer \(other.agentToken)"],
                                                                  body: Self.png(width: 64, height: 64))).decoded()
        let response = try await send("PUT", "/v1/notifications/done", body: [
            "sender": ["id": "printer", "name": "Printer", "avatar": .string(uploaded.id)], "body": "Done",
        ])
        #expect(response.status == 400)
    }

    @Test func aReferenceKeepsAMediumForADayAfterTheNotification() async throws {
        let device = try #require(try await store.device(agentToken: credentials.agentToken))
        let avatar = try await store.putMedium(device, bytes: Self.png(width: 256, height: 256), now: now).status.id
        let request = try NotificationRequest.decode(["sender": ["id": "printer", "name": "Printer", "avatar": .string(avatar.rawValue)], "body": "Done"])
        let used = now + Store.mediaRetention - 60
        #expect(try await store.putNotification(device, name: Name(rawValue: "first")!, request: request, now: used))
        try await store.housekeep(now: used + 120)
        #expect(try await store.putNotification(device, name: Name(rawValue: "second")!, request: request, now: used + 120))
        try await store.housekeep(now: used + 120 + Store.mediaRetention)
        await #expect(throws: APIError.self) {
            try await store.putNotification(device, name: Name(rawValue: "third")!, request: request, now: used + 120 + Store.mediaRetention)
        }
    }

    @Test func everyNotificationExampleIsServedListedAndSends() async throws {
        let folder = GatewayTests.exampleDirectory.appending(path: "notifications")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
        let reference = String(decoding: PackageResources.notifications_md, as: UTF8.self)
        var unused = Set(files.filter { !$0.hasSuffix(".json") })
        #expect(files.contains { $0.hasSuffix(".json") })
        for file in files {
            let served = await api.handle(HTTPRequest(method: "GET", target: "/skill/examples/notifications/\(file)", headers: [:], body: []))
            let expected = try Data(contentsOf: folder.appending(path: file))
            #expect(served.status == 200 && Data(served.body) == expected, "\(file)")
        }
        for file in files where file.hasSuffix(".json") {
            #expect(reference.contains("examples/notifications/\(file)"), "\(file)")
            var request = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: folder.appending(path: file)))
            for path in ["sender.avatar", "sound", "image"] {
                guard case let .string(medium)? = try? request.value(at: path) else { continue }
                unused.remove(medium)
                let uploaded: Uploaded = try await upload(Array(try Data(contentsOf: folder.appending(path: medium)))).decoded()
                request = try request.replacing(path, with: .string(uploaded.id))
            }
            #expect(try await send("PUT", "/v1/notifications/\(file.dropLast(5))", body: request).status == 201, "\(file)")
        }
        #expect(unused.isEmpty)
    }

    static func wav(milliseconds: Int, format: Int = 1, sampleRate: Int = 8000, declaredByteRate: Int? = nil, fill: UInt8 = 0) -> [UInt8] {
        let data = [UInt8](repeating: fill, count: sampleRate * 2 * milliseconds / 1000)
        let format: [[UInt8]] = [little(16, 4), little(format, 2), little(1, 2), little(sampleRate, 4), little(declaredByteRate ?? sampleRate * 2, 4),
                                 little(2, 2), little(16, 2)]
        let chunks: [[UInt8]] = [Array("RIFF".utf8), little(36 + data.count, 4), Array("WAVEfmt ".utf8)] + format + [Array("data".utf8), little(data.count, 4), data]
        return chunks.flatMap { $0 }
    }

    static func png(width: Int, height: Int) -> [UInt8] {
        let chunks: [[UInt8]] = [[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], big(13, 4), Array("IHDR".utf8), big(width, 4), big(height, 4),
                                 [8, 6, 0, 0, 0, 0, 0, 0, 0]]
        return chunks.flatMap { $0 }
    }

    static func jpeg(width: Int, height: Int) -> [UInt8] {
        let chunks: [[UInt8]] = [[0xFF, 0xD8, 0xFF, 0xE0], big(16, 2), Array("JFIF".utf8), [0, 1, 1, 0], big(1, 2), big(1, 2), [0, 0],
                                 [0xFF, 0xC0], big(11, 2), [8], big(height, 2), big(width, 2), [1, 1, 0x11, 0], [0xFF, 0xD9]]
        return chunks.flatMap { $0 }
    }

    private static func little(_ value: Int, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    private static func big(_ value: Int, _ count: Int) -> [UInt8] {
        little(value, count).reversed()
    }

    private struct Uploaded: Decodable, Equatable {
        let id: String
        let type: String
        let durationSeconds: Double?
    }

    private struct Phone {
        let api: API
        let credentials: Credentials

        init(now: Int) async throws {
            let store = try Store(path: ":memory:")
            api = API(store: store, maximumDevices: 1, maximumLiveActivities: 1, environments: [.development],
                      enrolment: Enrolment(appID: AppAttestTests.appID), version: nil, shutdown: Shutdown())
            let registration = Registration(environment: .development, appVersion: "0.5.4 (1)", proof: .invite(try await store.invite(now: now)))
            credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                           body: Array(try JSONEncoder().encode(registration)))).decoded()
        }

        func report(_ settings: NotificationSettings?) async throws {
            var report: [String: JSONValue] = ["appVersion": "0.5.4 (1)", "bundleInstance": .string(UUID().uuidString), "activities": .array([])]
            report["notifications"] = try settings.map { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode($0)) }
            #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                                 body: JSONValue.object(report).json)).status == 200)
        }

        func notify() async -> HTTPResponse {
            await api.handle(HTTPRequest(method: "PUT", target: "/v1/notifications/done",
                                         headers: ["authorization": "Bearer \(credentials.agentToken)"], body: NotificationTests.printer.json))
        }
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
        let last = try #require(try fetchTokens().last)
        return (last.id, last.token)
    }

    private func fetchTokens() throws -> [(id: UUID, token: String)] {
        try push.alerts.map { alert in
            guard case let .string(id) = try alert.payload.value(at: "lykta.id"), let uuid = UUID(uuidString: id),
                  case let .string(token) = try alert.payload.value(at: "lykta.token") else {
                throw LayoutError("the alert carries no notification id and token")
            }
            return (uuid, token)
        }
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

    private func upload(_ bytes: [UInt8]) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: "POST", target: "/v1/media", headers: ["authorization": "Bearer \(credentials.agentToken)"], body: bytes))
    }

    private func medium(_ id: UUID, _ medium: String, token: String) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: "GET", target: "/v1/device/notifications/\(id.uuidString)/media/\(medium)",
                                     headers: ["authorization": "Bearer \(token)"], body: []))
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
