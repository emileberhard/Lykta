import Foundation
import LyktaCore
import Synchronization

final class SimulatedPhone: PushService {
    static let credentials = Credentials(deviceSecret: "lykta_device_5c1d0b8e2f7a4c93b6e1d8f02a7c5e9b3d4f6a8c0e2b4d6f8a1c3e5b7d9f0a2c",
                                         agentToken: "lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")

    let environments: Set<PushEnvironment> = [.development]
    private let store: Store
    private let device: Device
    private let install = UUID()
    private let activities = Mutex<[String: UUID]>([:])

    init(store: Store, now: Int) async throws {
        try await store.registerDevice(environment: .development, appVersion: Layout.version.description,
                                       admission: .invited(try await store.invite(now: now)), credentials: Self.credentials,
                                       maximumDevices: 1, now: now)
        guard let device = try await store.device(secret: Self.credentials.deviceSecret) else {
            preconditionFailure("The simulated phone was just registered")
        }
        self.store = store
        self.device = device
        try await report([], now: now)
    }

    func start(_ payload: Data, deviceToken: PushToken, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        let aps = Self.decode(payload)
        guard let activity = aps.attributes?.id, let channel = aps.inputPushChannel else { preconditionFailure("Starts carry attributes and a channel") }
        activities.withLock { $0[channel] = activity }
        receive(aps, activity: activity)
        return id.uuidString.lowercased()
    }

    func broadcast(_ payload: Data, channel: String, priority: Int, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        if let activity = activities.withLock({ $0[channel] }) {
            receive(Self.decode(payload), activity: activity)
        }
        return id.uuidString.lowercased()
    }

    func createChannel(environment: PushEnvironment) async throws(APNsError) -> String {
        Data(UUID().uuidString.utf8.prefix(16)).base64EncodedString()
    }

    func deleteChannel(_ channel: String, environment: PushEnvironment) async throws(APNsError) {
        activities.withLock { _ = $0.removeValue(forKey: channel) }
    }

    func channels(environment: PushEnvironment) async throws(APNsError) -> [String] {
        activities.withLock { Array($0.keys) }
    }

    private func receive(_ aps: APS, activity: UUID) {
        let (name, state): (String, ObservedState) = switch aps.event {
        case .start: ("activity.observed", .active)
        case .update: ("activity.content", .active)
        case .end: ("activity.state", .ended)
        }
        Task {
            do {
                try await Task.sleep(for: .seconds(1))
                let now = Date()
                try await store.ingest(device, EventBatch(events: [
                    Event(id: UUID(), at: now, name: name, activity: activity, detail: .object([
                        "fingerprint": .string(aps.contentState.fingerprint), "layoutReadable": .bool(aps.contentState.layout != nil),
                        "state": .string(state.rawValue),
                    ])),
                ]))
                try await report([.init(id: activity, state: state)], now: Int(now.timeIntervalSince1970))
            } catch {
                log("The simulated phone failed to report \(name): \(error)")
            }
        }
    }

    private func report(_ observed: [DeviceReport.Observed], now: Int) async throws {
        _ = try await store.sync(device, report: DeviceReport(pushToStartToken: PushToken(Data(repeating: 7, count: 32)),
                                                              appVersion: Layout.version.description, layoutVersion: Layout.version,
                                                              bundleInstance: install, activities: observed), now: now)
    }

    private struct APS: Decodable {
        let event: Payload.Event
        let contentState: LyktaActivity.ContentState
        let attributes: LyktaActivity?
        let inputPushChannel: String?

        enum CodingKeys: String, CodingKey {
            case event, attributes
            case contentState = "content-state", inputPushChannel = "input-push-channel"
        }
    }

    private static func decode(_ payload: Data) -> APS {
        struct Pushed: Decodable { let aps: APS }
        do {
            return try JSONDecoder().decode(Pushed.self, from: payload).aps
        } catch {
            preconditionFailure("The gateway sent a payload its own types cannot decode: \(error)")
        }
    }
}
