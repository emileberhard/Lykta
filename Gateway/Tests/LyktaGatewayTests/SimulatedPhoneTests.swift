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
}
