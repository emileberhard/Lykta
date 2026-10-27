import Foundation
import LyktaCore
import Synchronization

final class SimulatedPhone: PushService {
    static let credentials = Credentials(deviceSecret: "lykta_device_5c1d0b8e2f7a4c93b6e1d8f02a7c5e9b3d4f6a8c0e2b4d6f8a1c3e5b7d9f0a2c",
                                         agentToken: "lykta_agent_9e2b7c4f1a8d3e6b0c5f9a2d7e4b1c8f3a6d0e9b2c5f8a1d4e7b0c3f6a9d2e5b")

    let environments: Set<PushEnvironment> = [.development]
    private let channels = Mutex<[String: UUID]>([:])
    private let pushes: AsyncStream<Push>.Continuation
    private let notifications: AsyncStream<Data>.Continuation
    private let store: Store
    private let device: Device
    private let widgetTask: Task<Void, Never>

    private struct Push {
        let aps: Payload.APS
        let activity: UUID
        let received: ContinuousClock.Instant
    }

    init(store: Store, now: Int) async throws {
        try await store.registerDevice(environment: .development, appVersion: Layout.version.description,
                                       admission: .invited(try await store.invite(now: now)), credentials: Self.credentials,
                                       maximumDevices: 1, now: now)
        guard let device = try await store.device(secret: Self.credentials.deviceSecret) else {
            preconditionFailure("The simulated phone was just registered")
        }
        self.store = store
        self.device = device
        _ = try await store.widgetCredential(device)
        widgetTask = Task {
            var known = Set<UUID>()
            while !Task.isCancelled {
                do {
                    let ids = Set(try await store.widgetSummaries(device).map(\.id))
                    if ids != known {
                        try await Self.refreshWidgets(in: store, device: device)
                        known = ids
                    }
                    try await Task.sleep(for: .milliseconds(250))
                } catch is CancellationError { return }
                catch {
                    log("The simulated phone failed to refresh widgets: \(error)")
                    return
                }
            }
        }
        let install = UUID()
        _ = try await store.sync(device, report: Self.report([:], install: install), now: now)
        let (received, pushes) = AsyncStream.makeStream(of: Push.self)
        self.pushes = pushes
        let (alerts, notifications) = AsyncStream.makeStream(of: Data.self)
        self.notifications = notifications
        Task {
            for await payload in alerts {
                do {
                    try await Task.sleep(for: .seconds(1))
                    try await Self.present(payload, in: store)
                } catch {
                    log("The simulated phone failed to present a notification: \(error)")
                }
            }
        }
        Task {
            var shown: [UUID: ObservedState] = [:]
            for await push in received {
                do {
                    try await Task.sleep(until: push.received + .seconds(1))
                    try await Self.show(push, on: &shown, of: device, install: install, in: store)
                } catch {
                    log("The simulated phone failed to show a \(push.aps.event.rawValue) push: \(error)")
                }
            }
        }
    }

    deinit {
        pushes.finish()
        notifications.finish()
        widgetTask.cancel()
    }

    func notify(_ payload: Data, deviceToken: PushToken, expiration: Int, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        notifications.yield(payload)
        return id.uuidString.lowercased()
    }

    func reloadWidgets(deviceToken: PushToken, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        do { try await Self.refreshWidgets(in: store, device: device) }
        catch { throw .unknown("The simulated phone failed to fetch widgets: \(error)") }
        return id.uuidString.lowercased()
    }

    private static func refreshWidgets(in store: Store, device: Device) async throws {
        let now = Int(Date().timeIntervalSince1970)
        let widgets = try await store.widgetList(device, now: now)
        var places: [WidgetPlace] = []
        for widget in widgets {
            let detail = try await store.widgetDetail(device, name: widget.name, now: now)
            let layout = try WidgetLayout(json: detail.layout.filled(with: detail.data, for: .widget).json)
            places += layout.presentations.keys.map { WidgetPlace(widget: widget.id, family: $0) }
        }
        try await store.reportWidgets(device, report: WidgetReport(pushToken: PushToken(Data(repeating: 9, count: 32)),
                                                                   layoutVersion: Layout.version, places: places), now: now)
        for place in places {
            _ = try await store.fetchWidget(device, id: place.widget, family: place.family, have: nil, layout: Layout.version, now: now)
        }
    }

    func start(_ payload: Data, deviceToken: PushToken, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        let aps = Self.decode(payload)
        guard let activity = aps.attributes?.id, let channel = aps.inputPushChannel else { preconditionFailure("Starts carry attributes and a channel") }
        channels.withLock { $0[channel] = activity }
        pushes.yield(Push(aps: aps, activity: activity, received: .now))
        return id.uuidString.lowercased()
    }

    func broadcast(_ payload: Data, channel: String, priority: Int, environment: PushEnvironment, id: UUID) async throws(APNsError) -> String? {
        if let activity = channels.withLock({ $0[channel] }) {
            pushes.yield(Push(aps: Self.decode(payload), activity: activity, received: .now))
        }
        return id.uuidString.lowercased()
    }

    func createChannel(environment: PushEnvironment) async throws(APNsError) -> String {
        Data(UUID().uuidString.utf8.prefix(16)).base64EncodedString()
    }

    func deleteChannel(_ channel: String, environment: PushEnvironment) async throws(APNsError) {
        channels.withLock { _ = $0.removeValue(forKey: channel) }
    }

    func channels(environment: PushEnvironment) async throws(APNsError) -> [String] {
        channels.withLock { Array($0.keys) }
    }

    private static func show(_ push: Push, on shown: inout [UUID: ObservedState], of device: Device, install: UUID, in store: Store) async throws {
        let now = Date()
        func event(_ name: String, _ detail: [String: JSONValue]) -> Event {
            Event(id: UUID(), at: now, name: name, activity: push.activity, detail: .object(detail))
        }
        let content: [String: JSONValue] = ["fingerprint": .string(push.aps.contentState.fingerprint),
                                            "layoutReadable": .bool(push.aps.contentState.layout != nil)]
        let events: [Event]
        switch push.aps.event {
        case .start:
            shown[push.activity] = .active
            events = [event("activity.observed", content.merging(["state": .string(ObservedState.active.rawValue)]) { $1 })]
        case .update:
            events = [event("activity.content", content)]
        case .end:
            shown[push.activity] = .ended
            events = [event("activity.content", content), event("activity.state", ["state": .string(ObservedState.ended.rawValue)])]
        }
        try await store.ingest(device, EventBatch(events: events))
        for ended in try await store.sync(device, report: report(shown, install: install), now: Int(now.timeIntervalSince1970)).end {
            shown[ended] = .ended
        }
    }

    private static func present(_ payload: Data, in store: Store) async throws {
        struct Alert: Decodable {
            struct APS: Decodable { let sound: String? }
            let aps: APS
            let lykta: NotificationPayload
        }
        let alert = try JSONDecoder().decode(Alert.self, from: payload)
        let lykta = alert.lykta
        let sound: NotificationReport.Sound = lykta.sound != nil ? .custom : alert.aps.sound == nil ? .none : .default
        try await store.reportNotification(lykta.id, token: lykta.token,
                                           NotificationReport(style: .communication(lykta.avatar == nil ? .initials : .image), sound: sound),
                                           now: Int(Date().timeIntervalSince1970))
    }

    private static func report(_ shown: [UUID: ObservedState], install: UUID) -> DeviceReport {
        DeviceReport(pushToStartToken: PushToken(Data(repeating: 7, count: 32)), appVersion: Layout.version.description,
                     layoutVersion: Layout.version, bundleInstance: install,
                     activities: shown.map { .init(id: $0.key, state: $0.value) },
                     notifications: NotificationSettings(authorization: .authorized, alertStyle: .banner,
                                                         registration: .registered(PushToken(Data(repeating: 8, count: 32)))))
    }

    private static func decode(_ payload: Data) -> Payload.APS {
        do {
            return try JSONDecoder().decode(Payload.self, from: payload).aps
        } catch {
            preconditionFailure("The gateway sent a payload its own types cannot decode: \(error)")
        }
    }
}
