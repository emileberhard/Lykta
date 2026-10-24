import Foundation
@testable import LyktaCore
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
        store = try Store(path: ":memory:")
        api = API(store: store, maximumDevices: 2, maximumLiveActivities: 2, environments: [.development],
                  enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(9, 9, 9), shutdown: Shutdown())
        credentials = try await api.handle(Self.registration(.invite(try await store.invite(now: now)))).decoded()
        _ = try await report([])
    }

    @Test func registersOnlyAttestedAppsAndInvitedDevices() async throws {
        let invite = try await store.invite(now: now)
        let refusals: [(Registration.Proof, String)] = [
            (.invite("lykta_invite_unknown"), "The invite is unknown, used or expired."),
            (.attestation(keyID: AppAttestTests.keyID, object: AppAttestTests.object, challenge: Data(count: 56)),
             "The challenge did not come from this gateway. Ask for a new one."),
            (.attestation(keyID: AppAttestTests.keyID, object: AppAttestTests.object, challenge: try await challenge()),
             "The app could not prove it is a genuine Lykta install: its certificate does not lead to Apple's App Attest root."),
        ]
        for (proof, message) in refusals {
            let response = await api.handle(Self.registration(proof))
            #expect(response.status == 403)
            #expect(try response.decoded() as Refusal == Refusal(error: "registration_refused", message: message))
        }
        #expect(await api.handle(Self.registration(.invite(invite))).status == 201)
        #expect(await api.handle(Self.registration(.invite(invite))).status == 403)
        let unproven = await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                    body: #"{"environment": "development", "appVersion": "1.0 (1)"}"#.utf8.map { $0 }))
        #expect(unproven.status == 400)
    }

    @Test func aPushFinishingAfterResetKeepsTheGatewayRunning() async throws {
        try await put("build", Self.start)
        let jobs = try await store.claim(now: now, limit: 4)
        let reset = await api.handle(HTTPRequest(method: "DELETE", target: "/v1/device",
                                                 headers: ["authorization": "Bearer \(credentials.deviceSecret)"], body: []))
        #expect(reset.status == 204)
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        for job in jobs {
            try await store.finish(job, try await delivery.send(job, now: now), now: now)
        }
        #expect(push.sent == ["createChannel"])
        #expect(try await store.channels().isEmpty)
    }

    @Test func aRestartingGatewayStartsNoNewRemoteStep() async throws {
        try await put("build", Self.start)
        let shutdown = Shutdown()
        let delivery = Delivery(store: store, push: push, shutdown: shutdown)
        let jobs = try await store.claim(now: now, limit: 4)
        shutdown.request()
        for job in jobs {
            try await store.finish(job, try await delivery.send(job, now: now), now: now)
        }
        try await deliver(at: now + 2)
        #expect(push.sent == ["createChannel", "start"])
        #expect(try await status("build") == Status(state: "live", delivery: "accepted", error: nil))
    }

    @Test func everyAcceptedChangeAdvancesTheRevision() async throws {
        try await put("build", ["title": "Build", "layout": Self.layout("Done")])
        try await put("build", ["layout": Self.layout("{{step}}"), "data": ["step": "Done"]])
        try await put("build", ["layout": Self.layout("{{step}}"), "data": ["step": "Done"]])
        try await put("build", ["endAfter": .number(600)])
        try await put("build", ["data": ["step": "Running"]])
        let detail: Detail = try await send("GET", "/v1/activities/build").decoded()
        #expect(detail.revision == 4)
        #expect(detail.data == ["step": "Running"])
    }

    @Test func eventCursorsNeverPointBackwards() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sqlite").path()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let old = try Store(path: path)
        let registered = Store.newCredentials()
        try await old.registerDevice(environment: .development, appVersion: "1.0 (1)", admission: .invited(try await old.invite(now: now)),
                                     credentials: registered, maximumDevices: 1, now: now)
        try Database(path: path).execute("""
            ALTER TABLE events RENAME TO new_events; DROP INDEX device_events; DROP INDEX event_age;
            CREATE TABLE events (
              seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
              activity_id TEXT, source TEXT NOT NULL CHECK (source IN ('app', 'gateway')), name TEXT NOT NULL, at INTEGER NOT NULL,
              received_at INTEGER NOT NULL, bytes INTEGER NOT NULL, detail TEXT NOT NULL
            ) STRICT;
            CREATE INDEX device_events ON events(device_id, seq);
            CREATE INDEX event_age ON events(received_at);
            INSERT INTO events SELECT * FROM new_events; DROP TABLE new_events; DELETE FROM sqlite_sequence WHERE name = 'events';
            """)
        let migrated = try Store(path: path)
        let first = try await migrated.events(device: nil, after: nil, limit: 10)
        #expect(first.map(\.name) == ["device.registered"])
        try await migrated.housekeep(now: now + Store.eventRetention + 60)
        let device = try #require(try await migrated.device(secret: registered.deviceSecret))
        try await migrated.ingest(device, EventBatch(events: [Event(id: UUID(), at: Date(), name: "app.launch", activity: nil, detail: [:])]))
        #expect(try await migrated.events(device: nil, after: first[0].seq, limit: 10).map(\.name) == ["app.launch"])
        await #expect(throws: APIError.self) { try await migrated.events(device: nil, after: first[0].seq + 5, limit: 10) }
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

    @Test func enforcesTheDeviceAndActivityLimits() async throws {
        #expect(await api.handle(Self.registration(.invite(try await store.invite(now: now)))).status == 201)
        let third = await api.handle(Self.registration(.invite(try await store.invite(now: now))))
        #expect(try third.decoded() as Failure == Failure(error: "registration_closed"))
        try await put("one", Self.start)
        try await put("two", Self.start)
        let extra = try await send("PUT", "/v1/activities/three", body: Self.start)
        #expect(try extra.decoded() as Failure == Failure(error: "too_many_activities"))
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

    @Test func refusesFeaturesThePhoneCannotDraw() async throws {
        let orbit: JSONValue = ["title": "Orbit", "layout": Self.layout(["svg": "<svg viewBox='0 0 1 1'><rect width='1' height='1'/></svg>"])]
        try await reportVersion("0.2.2 (7)", layoutVersion: nil)
        #expect(try await refusal("orbit", orbit)
            == "lockScreen.svg uses svg, which needs Lykta 0.2.4 or later, and this phone runs Lykta 0.2.2 (7). Ask the user to update Lykta and open it once, or send the layout without it.")
        try await put("build", Self.start)
        #expect(try await refusal("build", ["data": ["step": .number(5)]])?.hasPrefix("lockScreen uses number, which needs Lykta 0.2.3 or later") == true)
        try await reportVersion("1.0 (1)", layoutVersion: nil)
        #expect(try await refusal("orbit", orbit)?.contains("this phone's Lykta version (1.0 (1)) is unknown") == true)
        try await reportVersion("0.1.0 (1)", layoutVersion: Version(0, 2, 4))
        try await put("orbit", orbit)
        try await reportVersion("0.1.0 (1)", layoutVersion: Version(0, 2, 3))
        #expect(try await refusal("orbit", orbit)?.contains("and this phone's Lykta app draws layouts up to 0.2.3.") == true)
    }

    @Test func showsWhetherThePhoneCouldReadTheCurrentContent() async throws {
        let started: Identified = try await put("build", Self.start)
        let events: Events = try await send("GET", "/v1/events").decoded()
        let fingerprint = try #require(events.events.first { $0.name == "activity.put" }?.detail["fingerprint"])
        func observe(_ fingerprint: JSONValue, readable: Bool) async {
            let event = Event(id: UUID(), at: Date(), name: "activity.content", activity: started.id,
                              detail: ["fingerprint": fingerprint, "layoutReadable": .bool(readable)])
            _ = await api.handle(HTTPRequest(method: "POST", target: "/v1/device/events", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: Self.json(EventBatch(events: [event]))))
        }
        func readable() async throws -> Bool? {
            (try await send("GET", "/v1/activities/build").decoded() as Readability).layoutReadable
        }
        #expect(try await readable() == nil)
        await observe(fingerprint, readable: false)
        #expect(try await readable() == false)
        await observe(fingerprint, readable: true)
        #expect(try await readable() == true)
        await observe("another", readable: false)
        #expect(try await readable() == true)
        try await put("build", ["data": ["step": "Sign"]])
        #expect(try await readable() == nil)
    }

    @Test func reportsItsVersionWithoutAToken() async throws {
        let response = await api.handle(HTTPRequest(method: "GET", target: "/v1/version", headers: [:], body: []))
        #expect(try response.decoded() == ["version": "9.9.9"])
    }

    @Test func everyFeatureTheSkillUsesHasAVersion() throws {
        let markdown = String(decoding: PackageResources.layout_md, as: UTF8.self)
        let snippets = try markdown.components(separatedBy: "```json\n").dropFirst().map { block in
            try JSONDecoder().decode([String: JSONValue].self, from: Data(block.components(separatedBy: "\n```")[0].utf8))
        }
        #expect(!snippets.isEmpty)
        let examples = try Self.exampleFiles().map {
            try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: Self.exampleDirectory.appending(path: $0)))
        }
        var features: Set<String> = []
        for fields in snippets + examples {
            let layout: JSONValue = if let layout = fields["layout"] {
                try layout.filled(with: fields["data"] ?? .object([:]))
            } else {
                Self.layout(try JSONValue.object(fields).filled(with: Self.snippetData))
            }
            features.formUnion(try Layout(json: layout.json).features)
        }
        let unversioned = features.filter { Layout.introduced[$0] == nil }
        #expect(unversioned.isEmpty, "Add each new feature to Layout.introduced with the minor version that ships it: \(unversioned.sorted())")
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

    @Test func buttonsChangeTheDataTheyShow() async throws {
        let started: Identified = try await put("film", Self.film)
        try await deliver(at: now)
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("play"))).status == 409)
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("pause"))).status == 204)
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("pause"))).status == 409)
        var detail: Detail = try await send("GET", "/v1/activities/film").decoded()
        #expect(detail.revision == 2)
        #expect(abs(try detail.data.number(at: "pausedAt") - Double(now)) < 5)
        #expect(try detail.data.value(at: "playing") == .bool(false))
        try await deliver(at: now + 1)
        #expect(push.sent == ["createChannel", "start", "update 5"])
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("play"))).status == 204)
        detail = try await send("GET", "/v1/activities/film").decoded()
        #expect(detail.revision == 3)
        #expect(try detail.data.value(at: "pausedAt") == .null)
        let pressed: Actions = try await send("GET", "/v1/actions?after=0").decoded()
        #expect(pressed.actions.map(\.button) == ["pause", "play"])
    }

    @Test func aPressTheLayoutCannotShowChangesNothing() async throws {
        let started: Identified = try await put("recipe", Self.recipe)
        #expect(await act(Action(id: UUID(), activity: started.id, input: .button("next"))).status == 204)
        let refused = await act(Action(id: UUID(), activity: started.id, input: .button("next")))
        #expect(refused.status == 409)
        #expect(try refused.decoded() as Failure == Failure(error: "conflict"))
        let detail: Detail = try await send("GET", "/v1/activities/recipe").decoded()
        #expect(detail.revision == 2)
        #expect(try detail.data.value(at: "step") == .number(2))
        let pressed: Actions = try await send("GET", "/v1/actions?after=0").decoded()
        #expect(pressed.actions.count == 1)
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
        try await store.housekeep(now: now + Store.actionRetention + 60)
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

    @Test func everyExampleIsServedListedAndStarts() async throws {
        let files = try Self.exampleFiles()
        let skill = String(decoding: PackageResources.SKILL_md, as: UTF8.self)
        #expect(!files.isEmpty)
        for file in files {
            let served = await api.handle(HTTPRequest(method: "GET", target: "/skill/examples/\(file)", headers: [:], body: []))
            #expect(served.status == 200, "\(file)")
            #expect(Data(served.body) == (try Data(contentsOf: Self.exampleDirectory.appending(path: file))), "\(file)")
            #expect(skill.contains("examples/\(file)"), "\(file)")
            try await put("example", try JSONDecoder().decode(JSONValue.self, from: Data(served.body)))
            _ = try await send("DELETE", "/v1/activities/example")
        }
    }

    static let exampleDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/LyktaGateway/Skill/examples")

    static func exampleFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: exampleDirectory.path(percentEncoded: false)).filter { $0.hasSuffix(".json") }
    }

    static let snippetData: JSONValue = [
        "steps": .array([["name": "Build"], ["name": "Test"]]), "items": .array([["name": "Milk", "done": .bool(false)]]), "step": "Mix", "index": .number(1),
        "progress": .number(0.6), "paused": .bool(true), "pausedAt": .number(1_793_000_000), "start": .number(1_792_999_000), "end": .number(1_793_002_000),
    ]

    static func layout(_ lockScreen: JSONValue) -> JSONValue {
        ["lockScreen": lockScreen, "compactLeading": "a", "compactTrailing": "b", "minimal": "c"]
    }

    static let start: JSONValue = [
        "title": "Build",
        "layout": layout("{{step}}"),
        "data": ["step": "Compile"],
    ]

    static let checklist: JSONValue = [
        "title": "Shopping",
        "layout": layout(["vstack": .array([["each": "items", "as": "item", "do": ["toggle": "item.done", "label": "{{item.name}}"]]])]),
        "data": ["items": .array([["name": "Milk", "done": .bool(false)]])],
    ]

    static let question: JSONValue = [
        "title": "Deploy failed",
        "layout": layout(["hstack": .array([["button": "retry", "label": "Retry"], ["button": "stop", "label": "Stop"]])]),
    ]

    static let film: JSONValue = [
        "title": "Film",
        "layout": layout(["if": "{{playing}}",
                          "then": ["button": "pause", "label": "Pause", "now": ["pausedAt": .number(0)], "set": ["playing": .bool(false)]],
                          "else": ["button": "play", "label": "Play", "set": ["pausedAt": .null, "playing": .bool(true)],
                                   "add": ["start": ["since": "pausedAt"]]]]),
        "data": ["playing": .bool(true), "pausedAt": .null, "start": .number(1_793_000_000)],
    ]

    static let recipe: JSONValue = [
        "title": "Recipe",
        "layout": layout(["vstack": .array(["{{steps[step]}}", ["button": "next", "label": "Next", "add": ["step": .number(1)]]])]),
        "data": ["step": .number(1), "steps": ["1": "Chop", "2": "Fry"]],
    ]

    static let oversized = layout(["vstack": .array((0..<200).map { _ in .string(UUID().uuidString) })])

    @discardableResult
    private func put(_ name: String, _ body: JSONValue) async throws -> Identified {
        let response = try await send("PUT", "/v1/activities/\(name)", body: body)
        #expect(response.status == 200, "\(String(decoding: response.body, as: UTF8.self))")
        return try response.decoded()
    }

    private func status(_ name: String) async throws -> Status {
        try await send("GET", "/v1/activities/\(name)").decoded()
    }

    private func reportVersion(_ appVersion: String, layoutVersion: Version?) async throws {
        var report: [String: JSONValue] = ["pushToStartToken": "abcdef", "appVersion": .string(appVersion),
                                           "bundleInstance": .string(bundleInstance.uuidString), "activities": .array([])]
        report["layoutVersion"] = layoutVersion.map { .string($0.description) }
        let response = await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                                    body: JSONValue.object(report).json))
        #expect(response.status == 200)
    }

    private func refusal(_ name: String, _ body: JSONValue) async throws -> String? {
        let response = try await send("PUT", "/v1/activities/\(name)", body: body)
        let failure: Refusal = try response.decoded()
        #expect(response.status == 409 && failure.error == "app_update_required", "\(failure.message)")
        return failure.message
    }

    private func report(_ activities: [DeviceReport.Observed]) async throws -> SyncResult {
        let report = DeviceReport(pushToStartToken: PushToken(hex: "abcdef"), appVersion: "1.0 (1)", layoutVersion: Layout.version, bundleInstance: bundleInstance,
                                  activities: activities, notifications: NotificationSettings(authorization: .notDetermined, alertStyle: .banner, registration: .pending))
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
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        for job in try await store.claim(now: time, limit: 4) {
            try await store.finish(job, try await delivery.send(job, now: time), now: time)
        }
    }

    private func challenge() async throws -> Data {
        let response = await api.handle(HTTPRequest(method: "GET", target: "/v1/devices/challenge", headers: [:], body: []))
        return (try response.decoded() as Challenge).challenge
    }

    private static func registration(_ proof: Registration.Proof) -> HTTPRequest {
        HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                    body: json(Registration(environment: .development, appVersion: "1.0 (1)", proof: proof)))
    }

    private static func json(_ value: some Encodable) -> [UInt8] {
        Array(try! JSONEncoder().encode(value))
    }
}
