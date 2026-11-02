import Foundation
import LyktaCore
import Testing
@testable import LyktaGateway

struct RenderTests {
    private let store: Store
    private let api: API
    private let credentials: Credentials
    private let now = Int(Date().timeIntervalSince1970)
    private static let worker = "lykta_render_worker"
    private static let activity: JSONValue = [
        "title": "Deploy", "layout": ["lockScreen": ["use": "word"], "compactLeading": "{{step}}", "compactTrailing": "", "minimal": ""],
        "data": ["step": "Build"], "now": ["started": .number(0)],
    ]

    init() async throws {
        store = try Store(path: ":memory:")
        api = API(store: store, maximumDevices: 2, maximumLiveActivities: 2, environments: [.development],
                  enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(9, 9, 9), shutdown: Shutdown(),
                  renders: RenderQueue(workerTokenHash: Store.hash(Self.worker)))
        credentials = try await Self.register(api, store: store, now: now)
        #expect(await send("PUT", "/v1/parts/word", "Saved").status == 201)
    }

    @Test func refusesToRenderWhileNoRendererPolls() async throws {
        let response = await send("POST", "/v1/render/activities/deploy", Self.activity)
        #expect(response.status == 503)
        #expect(try response.decoded() as Refusal == Refusal(error: "render_unavailable",
                                                               message: "No renderer is connected to this gateway. Send the PUT and look at the phone instead."))
    }

    @Test func theWorkerDrawsTheExpandedFilledRequestAndOnlyItsPhoneReadsTheImage() async throws {
        let (job, reply) = try await render("/v1/render/activities/deploy", Self.activity,
                                            answer: ["image": "AQID", "warnings": .array(["lock is 182 points tall; the Lock Screen shows 160"])])
        #expect(try job.value(at: "input.layout.lockScreen") == "Saved")
        #expect(try job.value(at: "input.data.step") == "Build")
        guard case let .number(started) = try job.value(at: "input.data.started") else { throw LayoutError("started is missing") }
        #expect(Int(started) >= now)
        #expect(try job.value(at: "presentations") == .array(["lock", "expanded", "compact", "minimal"]))
        #expect(reply.status == 200)
        let id = try job.value(at: "id")
        #expect(try reply.decoded() as JSONValue == ["id": id, "warnings": .array(["lock is 182 points tall; the Lock Screen shows 160"])])
        guard case let .string(image) = id else { throw LayoutError("the job has no id") }
        let drawn = await send("GET", "/v1/render/images/\(image)")
        #expect(drawn.status == 200 && drawn.contentType == "image/png" && drawn.body == [1, 2, 3])
        let other = try await Self.register(api, store: store, now: now)
        let foreign = await api.handle(HTTPRequest(method: "GET", target: "/v1/render/images/\(image)",
                                                   headers: ["authorization": "Bearer \(other.agentToken)"], body: []))
        #expect(foreign.status == 404)
    }

    @Test(arguments: [
        ("/v1/render/activities/deploy", ["title": "Deploy", "layout": ["lockScreen": "Hi"]] as JSONValue, "invalid_layout"),
        ("/v1/render/activities/deploy", ["title": "Deploy", "layout": GatewayTests.oversized] as JSONValue, "payload_too_large"),
        ("/v1/render/activities/deploy", ["title": "Deploy", "layout": ["lockScreen": ["use": "missing"], "compactLeading": "", "compactTrailing": "", "minimal": ""]] as JSONValue, "invalid_layout"),
        ("/v1/render/widgets/steps", ["title": "Steps"] as JSONValue, "invalid_request"),
        ("/v1/render/notifications/done", ["sender": ["id": "bot", "name": "Bot"], "body": "Done", "image": "m_0123456789abcdef0123456789abcdef"] as JSONValue, "invalid_request"),
        ("/v1/render/parts/badge", ["parts": ["a": "A"], "use": "a"] as JSONValue, "invalid_layout"),
    ])
    func refusesWhatThePutWouldRefuseBeforeQueueing(_ path: String, _ body: JSONValue, _ error: String) async throws {
        #expect(await work("GET", "/v1/render/jobs").status == 204)
        let response = await send("POST", path, body)
        #expect((try response.decoded() as Refusal).error == error)
        #expect(await work("GET", "/v1/render/jobs").status == 204)
    }

    @Test func rendersADataOnlyUpdateWithTheActivitysStoredLayout() async throws {
        #expect(await send("PUT", "/v1/activities/deploy", Self.activity).status == 200)
        let (job, _) = try await render("/v1/render/activities/deploy", ["data": ["step": "Ship"]])
        #expect(try job.value(at: "input.layout.compactLeading") == "{{step}}")
        #expect(try job.value(at: "input.data") == ["step": "Ship"])
        #expect(try job.value(at: "input.title") == "Deploy")
    }

    @Test func sendsAPartAsALockScreenAndANotificationWithItsMedia() async throws {
        let (part, _) = try await render("/v1/render/parts/badge", ["use": "word"])
        #expect(try part.value(at: "presentations") == .array(["lock"]))
        #expect(try part.value(at: "input.layout.lockScreen") == "Saved")
        let picture = NotificationTests.png(width: 256, height: 256)
        let uploaded = await api.handle(HTTPRequest(method: "POST", target: "/v1/media", headers: ["authorization": "Bearer \(credentials.agentToken)"], body: picture))
        let medium: JSONValue = try uploaded.decoded()
        let (notification, _) = try await render("/v1/render/notifications/done", [
            "sender": ["id": "bot", "name": "Build Bot", "avatar": try medium.value(at: "id")], "body": "Done", "sound": .bool(true),
        ])
        #expect(try notification.value(at: "presentations") == .array(["banner", "avatar"]))
        #expect(try notification.value(at: "input.sender") == ["id": "bot", "name": "Build Bot"])
        #expect(try notification.value(at: "input.avatar.image") == .string(Data(picture).base64EncodedString()))
    }

    @Test func passesOnWhatTheRendererCouldNotDraw() async throws {
        let (_, reply) = try await render("/v1/render/widgets/steps", ["title": "Steps", "layout": ["systemSmall": "{{steps}}"], "data": ["steps": "10"]],
                                          answer: ["error": "these presentations draw nothing: steps-small"])
        #expect(reply.status == 502)
        #expect(try reply.decoded() as Refusal == Refusal(error: "render_failed", message: "The renderer could not draw it: these presentations draw nothing: steps-small"))
    }

    @Test func onlyTheWorkerTokenClaimsAndAnswersJobs() async throws {
        let claimed = await api.handle(HTTPRequest(method: "GET", target: "/v1/render/jobs", headers: ["authorization": "Bearer \(credentials.agentToken)"], body: []))
        #expect(claimed.status == 401)
        #expect(await work("PUT", "/v1/render/jobs/\(UUID().uuidString)", ["image": "AQID"]).status == 404)
    }

    private func render(_ path: String, _ body: JSONValue, answer: JSONValue = ["image": "AQID"]) async throws -> (job: JSONValue, reply: HTTPResponse) {
        #expect(await work("GET", "/v1/render/jobs").status == 204)
        async let reply = send("POST", path, body)
        let job: JSONValue = try await work("GET", "/v1/render/jobs?wait=5").decoded()
        guard case let .string(id) = try job.value(at: "id") else { throw LayoutError("the job has no id") }
        #expect(await work("PUT", "/v1/render/jobs/\(id)", answer).status == 204)
        return (job, await reply)
    }

    private func send(_ method: String, _ path: String, _ body: JSONValue? = nil) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: path, headers: ["authorization": "Bearer \(credentials.agentToken)"], body: body?.json ?? []))
    }

    private func work(_ method: String, _ path: String, _ body: JSONValue? = nil) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: path, headers: ["authorization": "Bearer \(Self.worker)"], body: body?.json ?? []))
    }

    private static func register(_ api: API, store: Store, now: Int) async throws -> Credentials {
        let registration = Registration(environment: .development, appVersion: Layout.version.description, proof: .invite(try await store.invite(now: now)))
        let credentials: Credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                                         body: Array(try JSONEncoder().encode(registration)))).decoded()
        let report: JSONValue = ["pushToStartToken": "abcdef", "appVersion": .string(Layout.version.description),
                                 "layoutVersion": .string(Layout.version.description), "bundleInstance": .string(UUID().uuidString), "activities": .array([])]
        #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: report.json)).status == 200)
        return credentials
    }
}
