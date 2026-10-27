import Foundation
import LyktaCore
import Testing
@testable import LyktaGateway

struct SimulatedPhoneTests {
    private struct Shown: Decodable, Equatable {
        let state: String
        let device: String?
        let layoutReadable: Bool?
    }

    @Test func showsUpdatesAndEndsWhatAnAgentStarts() async throws {
        let store = try Store(path: ":memory:")
        let now = Int(Date().timeIntervalSince1970)
        let phone = try await SimulatedPhone(store: store, now: now)
        let api = API(store: store, maximumDevices: 1, maximumLiveActivities: 5, environments: phone.environments,
                      enrolment: Enrolment(appID: "simulated"), version: nil, shutdown: Shutdown())
        let delivery = Delivery(store: store, push: phone, shutdown: Shutdown())
        var time = now

        func request(_ method: String, _ body: JSONValue? = nil) async {
            let response = await api.handle(HTTPRequest(method: method, target: "/v1/activities/build",
                                                         headers: ["authorization": "Bearer \(SimulatedPhone.credentials.agentToken)"],
                                                         body: body?.json ?? []))
            #expect(response.status == 200, "\(String(decoding: response.body, as: UTF8.self))")
        }

        func deliver() async throws {
            time += 1
            for job in try await store.claim(now: time, limit: 4) {
                try await store.finish(job, try await delivery.send(job, now: time), now: time)
            }
        }

        func shown(_ expected: Shown) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var shown: Shown
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                shown = try await api.handle(HTTPRequest(method: "GET", target: "/v1/activities/build",
                                                         headers: ["authorization": "Bearer \(SimulatedPhone.credentials.agentToken)"],
                                                         body: [])).decoded()
            } while shown != expected && ContinuousClock.now < deadline
            #expect(shown == expected)
        }

        await request("PUT", GatewayTests.start)
        try await deliver()
        try await shown(Shown(state: "live", device: "active", layoutReadable: true))
        await request("PUT", ["layout": GatewayTests.layout("{{step}}"), "data": ["step": "Build"]])
        try await deliver()
        await request("PUT", ["layout": GatewayTests.layout("{{step}}"), "data": ["step": "Test"]])
        await request("DELETE")
        try await deliver()
        try await shown(Shown(state: "ended", device: "ended", layoutReadable: true))
    }

    @Test func placesNewWidgetsAndFetchesTheirUpdatesWhenPushed() async throws {
        struct Widget: Decodable {
            let revision: Int
            let delivery: String
            let placed: [WidgetLayout.Family]
        }
        let store = try Store(path: ":memory:")
        let now = Int(Date().timeIntervalSince1970)
        let phone = try await SimulatedPhone(store: store, now: now)
        let api = API(store: store, maximumDevices: 1, maximumLiveActivities: 5, environments: phone.environments,
                      enrolment: Enrolment(appID: "simulated"), version: nil, shutdown: Shutdown())
        func request(_ method: String, _ body: JSONValue? = nil) async -> HTTPResponse {
            await api.handle(HTTPRequest(method: method, target: "/v1/widgets/steps",
                                         headers: ["authorization": "Bearer \(SimulatedPhone.credentials.agentToken)"], body: body?.json ?? []))
        }
        #expect(await request("PUT", ["title": "Steps", "layout": ["systemSmall": ["text": "{{steps}}"]], "data": ["steps": "10"]]).status == 201)
        let deadline = ContinuousClock.now + .seconds(5)
        var shown: Widget
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            shown = try await request("GET").decoded()
        } while shown.delivery != "fetched" && ContinuousClock.now < deadline
        #expect(shown.delivery == "fetched")
        #expect(shown.placed == [.systemSmall])
        #expect(await request("PUT", ["data": ["steps": "20"]]).status == 200)
        let delivery = Delivery(store: store, push: phone, shutdown: Shutdown())
        for job in try await store.claim(now: now + 1, limit: 4) {
            try await store.finish(job, try await delivery.send(job, now: now + 1), now: now + 1)
        }
        let updated: Widget = try await request("GET").decoded()
        #expect(updated.revision == 2)
        #expect(updated.delivery == "fetched")
    }

}
