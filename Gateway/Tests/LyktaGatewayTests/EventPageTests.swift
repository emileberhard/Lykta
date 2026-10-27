import Foundation
import LyktaCore
import Testing
@testable import LyktaGateway

struct EventPageTests {
    @Test func pagesKeepTheirDeviceAndResumeAcrossOtherDevices() async throws {
        let store = try Store(path: ":memory:")
        var devices: [Device] = []
        for _ in 0..<2 {
            let credentials = Store.newCredentials()
            try await store.registerDevice(environment: .development, appVersion: "0.15.0",
                                           admission: .invited(try await store.invite(now: 100)), credentials: credentials,
                                           maximumDevices: 2, now: 100)
            devices.append(try #require(await store.device(secret: credentials.deviceSecret)))
        }
        for (device, name) in zip(devices, ["app.first", "app.second"]) {
            try await store.ingest(device, EventBatch(events: [Event(id: UUID(), at: Date(timeIntervalSince1970: 100),
                                                                    name: name, activity: nil, detail: .object([:]))]))
        }
        let latest = try await store.events(device: devices[0].id, after: nil, limit: 1)
        #expect(latest.map(\.name) == ["app.first"])
        let first = try #require(latest.first)
        #expect(try await store.events(device: devices[0].id, after: first.seq, limit: 1).isEmpty)
        #expect(try await store.events(device: devices[1].id, after: first.seq, limit: 1).map(\.name) == ["app.second"])
        #expect(try await store.events(device: nil, after: first.seq, limit: 1).map(\.name) == ["app.second"])
        #expect(try await store.events(device: nil, after: nil, limit: 2).map(\.name) == ["app.first", "app.second"])
        #expect(try await store.events(device: devices[0].id, after: 0, limit: 1).map(\.name) == ["device.registered"])
    }
}
