import Foundation
import Testing
@testable import LyktaCore
@testable import LyktaGateway

struct PartsStorageTests {
    @Test func admissionStoresExpandedTemplatesForLaterUpdatesAndTaps() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).sqlite").path()
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let store = try Store(path: path)
        let now = Int(Date().timeIntervalSince1970)
        let api = API(store: store, maximumDevices: 1, maximumLiveActivities: 1, environments: [.development],
                      enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(9, 9, 9), shutdown: Shutdown())
        let credentials: Credentials = try await api.handle(HTTPRequest(
            method: "POST", target: "/v1/devices", headers: [:],
            body: Array(try JSONEncoder().encode(Registration(environment: .development, appVersion: "1.0 (1)",
                                                            proof: .invite(try await store.invite(now: now))))))).decoded()
        let settings: JSONValue = ["pushToStartToken": "abcdef", "appVersion": "0.7.1", "bundleInstance": .string(UUID().uuidString), "activities": .array([])]
        #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: settings.json)).status == 200)
        func send(_ method: String, _ body: JSONValue?) async -> HTTPResponse {
            await api.handle(HTTPRequest(method: method, target: "/v1/activities/parts", headers: ["authorization": "Bearer \(credentials.agentToken)"],
                                         body: body?.json ?? []))
        }
        let template: JSONValue = [
            "parts": ["row": ["hstack": .array([["toggle": "done", "label": "{{name}}"],
                                                ["button": "increment", "label": "{{count}}", "add": ["count": .number(1)]]])]],
            "lockScreen": ["use": "row"], "compactLeading": "", "compactTrailing": "", "minimal": "",
        ]
        let response = await send("PUT", ["title": "Parts", "layout": template, "data": ["name": "First", "done": .bool(false), "count": .number(0)]])
        #expect(response.status == 200, "\(String(decoding: response.body, as: UTF8.self))")
        let activity: Identified = try response.decoded()
        let database = try Database(path: path)
        let stored = try #require(database.query("SELECT layout FROM activities").first).string("layout")
        let expanded: JSONValue = ["lockScreen": ["hstack": .array([["toggle": "done", "label": "{{name}}"],
                                                                   ["button": "increment", "label": "{{count}}", "add": ["count": .number(1)]]])],
                                   "compactLeading": "", "compactTrailing": "", "minimal": ""]
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(stored.utf8)) == expanded)
        let delivery = Delivery(store: store, push: FakePush(), shutdown: Shutdown())
        for job in try await store.claim(now: now, limit: 4) {
            try await store.finish(job, try await delivery.send(job, now: now), now: now)
        }
        #expect(await send("PUT", ["data": ["name": "Updated", "done": .bool(false), "count": .number(3)]]).status == 200)
        for input: Action.Input in [.toggle("done", isOn: true), .button("increment")] {
            let action = Action(id: UUID(), activity: activity.id, input: input)
            #expect(await api.handle(HTTPRequest(method: "POST", target: "/v1/device/actions", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                                 body: Array(try JSONEncoder().encode(action)))).status == 204)
        }
        let detail: Detail = try await send("GET", nil).decoded()
        #expect(detail.revision == 4)
        #expect(detail.data == ["name": "Updated", "done": .bool(true), "count": .number(4)])
        #expect(try database.query("SELECT layout FROM activities")[0].string("layout") == stored)
    }
}
