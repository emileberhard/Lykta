import ActivityKit
import Foundation
import LyktaCore
import MetricKit
import Observation
import SwiftUI
import UIKit

@Observable
final class Model {
    enum Phase {
        case unconfigured, connecting, ready
        case failed(String)
    }

    private(set) var phase: Phase
    private(set) var activities: [LiveActivity] = []
    private(set) var areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var error: String?

    private let gateway: GatewayClient?
    private let environment: PushEnvironment
    private let queue = EventQueue()
    private let metrics = MetricManager()
    private var credentials: Credentials?
    private var pushToken: PushToken?
    private var runTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let environment = (info["LyktaPushEnvironment"] as? String).flatMap(PushEnvironment.init) else {
            preconditionFailure("Info.plist needs LyktaPushEnvironment")
        }
        let host = info["LyktaGatewayHost"] as? String ?? ""
        self.environment = environment
        gateway = host.isEmpty ? nil : URL(string: "https://\(host)").map(GatewayClient.init)
        phase = gateway == nil ? .unconfigured : .connecting
    }

    func start() {
        if metricsTask == nil {
            let authorization = ActivityAuthorizationInfo()
            record("app.launch", [
                "appVersion": .string(Self.appVersion), "os": .string(UIDevice.current.systemVersion), "hardware": .string(Self.hardware),
                "environment": .string(environment.rawValue), "applicationState": .string(Self.describe(UIApplication.shared.applicationState)),
                "activitiesEnabled": .bool(authorization.areActivitiesEnabled), "frequentPushesEnabled": .bool(authorization.frequentPushesEnabled),
                "activities": .number(Double(Activity<LyktaActivity>.activities.count)),
            ])
            metricsTask = Task {
                await withDiscardingTaskGroup { group in
                    group.addTask { await self.observeDiagnostics() }
                    group.addTask { await self.observeMetrics() }
                }
            }
        }
        if case .failed = phase {
            phase = .connecting
        }
        runTask?.cancel()
        runTask = Task { await run() }
    }

    func sceneChanged(to scenePhase: ScenePhase) {
        let name = switch scenePhase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        record("app.scene", ["phase": .string(name)])
    }

    func copySetup() {
        guard let gateway, let credentials else { return }
        record("app.copySetup")
        UIPasteboard.general.string = """
            Show Live Activities on my iPhone with Lykta.
            Gateway: \(gateway.url.absoluteString)
            Token: \(credentials.agentToken)
            Instructions: \(gateway.url.appending(path: "skill/SKILL.md").absoluteString)
            """
    }

    func sendDemo() async -> Bool {
        guard let gateway, let credentials else { return false }
        record("app.demo")
        let isShowing = Activity<LyktaActivity>.activities.contains { $0.attributes.name == "demo" && $0.activityState == .active }
        return await showingErrors("demo") {
            if !isShowing {
                try await gateway.endActivity("demo", agentToken: credentials.agentToken)
            }
            try await gateway.putActivity("demo", title: Demo.title, layout: Demo.layout, data: Demo.data(start: .now),
                                          agentToken: credentials.agentToken)
        }
    }

    func reset() async {
        guard let gateway, let credentials else { return }
        record("app.reset")
        await showingErrors("reset") {
            try await gateway.deleteDevice(secret: credentials.deviceSecret)
            Keychain.delete()
            self.credentials = nil
            for activity in Activity<LyktaActivity>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            activities = []
            phase = .connecting
        }
    }

    private func run() async {
        guard let gateway else { return }
        do {
            if let saved = try Keychain.load() {
                credentials = saved
            } else {
                let registered = try await gateway.register(Registration(environment: environment, appVersion: Self.appVersion))
                try Keychain.save(registered)
                credentials = registered
                record("app.registered")
            }
            phase = .ready
        } catch {
            record("app.error", ["operation": .string("connect"), "error": .string(error.localizedDescription)])
            phase = .failed(error.localizedDescription)
            return
        }
        scheduleFlush()
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observePushTokens() }
            group.addTask { await self.observeActivities() }
            group.addTask { await self.observeAuthorization() }
        }
    }

    private func observePushTokens() async {
        for await token in Activity<LyktaActivity>.pushToStartTokenUpdates {
            pushToken = PushToken(token)
            record("activity.pushToStartToken", ["fingerprint": .string(fingerprint(PushToken(token).description.utf8))])
            await sync()
        }
    }

    private func observeActivities() async {
        await withDiscardingTaskGroup { group in
            for id in Activity<LyktaActivity>.activities.map(\.id) {
                group.addTask { await self.observe(id) }
            }
            await sync()
            for await activity in Activity<LyktaActivity>.activityUpdates {
                let id = activity.id
                group.addTask { await self.observe(id) }
            }
        }
    }

    private func observe(_ id: String) async {
        guard let activity = Activity<LyktaActivity>.activities.first(where: { $0.id == id }) else {
            record("activity.vanished", ["activityKitID": .string(id)])
            return
        }
        record("activity.observed", activity: activity.attributes.id, Self.describe(activity))
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeState(of: id) }
            group.addTask { await self.observeContent(of: id) }
        }
    }

    private func observeState(of id: String) async {
        guard let activity = Activity<LyktaActivity>.activities.first(where: { $0.id == id }) else { return }
        for await state in activity.activityStateUpdates {
            record("activity.state", activity: activity.attributes.id, ["state": .string(ObservedState(state).rawValue)])
            await sync()
        }
    }

    private func observeContent(of id: String) async {
        guard let activity = Activity<LyktaActivity>.activities.first(where: { $0.id == id }) else { return }
        for await content in activity.contentUpdates {
            record("activity.content", activity: activity.attributes.id, Self.describe(content))
            activities = Activity<LyktaActivity>.activities.map(LiveActivity.init)
        }
    }

    private func observeAuthorization() async {
        for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
            areActivitiesEnabled = enabled
            record("app.authorization", ["activitiesEnabled": .bool(enabled)])
        }
    }

    private func observeDiagnostics() async {
        for await report in metrics.diagnosticReports {
            record("metrickit.diagnostic", Self.detail(of: report))
        }
    }

    private func observeMetrics() async {
        for await report in metrics.metricReports {
            record("metrickit.metrics", Self.detail(of: report))
        }
    }

    private func sync() async {
        guard let gateway, let credentials else { return }
        let observed = Activity<LyktaActivity>.activities
        activities = observed.map(LiveActivity.init)
        let deviceReport = DeviceReport(pushToStartToken: pushToken, appVersion: Self.appVersion, bundleInstance: Self.bundleInstance,
                                        activities: observed.map { .init(id: $0.attributes.id, state: ObservedState($0.activityState)) })
        await showingErrors("sync") {
            let result = try await gateway.sync(deviceReport, secret: credentials.deviceSecret)
            for activity in Activity<LyktaActivity>.activities where result.end.contains(activity.attributes.id) {
                record("activity.endedByGateway", activity: activity.attributes.id)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activities = Activity<LyktaActivity>.activities.map(LiveActivity.init)
    }

    @discardableResult
    private func showingErrors(_ operation: String, _ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            error = nil
            return true
        } catch {
            record("app.error", ["operation": .string(operation), "error": .string(error.localizedDescription)])
            self.error = error.localizedDescription
            return false
        }
    }

    private func record(_ name: String, activity: UUID? = nil, _ detail: [String: JSONValue] = [:]) {
        queue.append(Event(id: UUID(), at: .now, name: name, activity: activity, detail: .object(detail)))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .seconds(1))
            await flush()
            flushTask = nil
        }
    }

    private func flush() async {
        guard let gateway, let credentials else { return }
        while !queue.events.isEmpty {
            let batch = queue.batch()
            do {
                try await gateway.upload(EventBatch(events: batch), secret: credentials.deviceSecret)
            } catch let error as AppError where error.status == 400 || error.status == 413 {
                queue.remove(batch)
                queue.append(Event(id: UUID(), at: .now, name: "telemetry.rejected", activity: nil, detail: .object([
                    "events": .number(Double(batch.count)), "error": .string(error.localizedDescription),
                ])))
                return
            } catch {
                return
            }
            queue.remove(batch)
        }
    }

    private static func describe(_ activity: Activity<LyktaActivity>) -> [String: JSONValue] {
        describe(activity.content).merging([
            "name": .string(activity.attributes.name), "activityKitID": .string(activity.id),
            "state": .string(ObservedState(activity.activityState).rawValue),
        ]) { $1 }
    }

    private static func describe(_ content: ActivityContent<LyktaActivity.ContentState>) -> [String: JSONValue] {
        [
            "fingerprint": .string(content.state.fingerprint), "layoutReadable": .bool(content.state.layout != nil),
            "staleDate": content.staleDate.map { .string($0.ISO8601Format()) } ?? .null, "relevance": .number(content.relevanceScore),
        ]
    }

    private static func describe(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private static func detail(of report: some Encodable) -> [String: JSONValue] {
        do {
            let data = try JSONEncoder().encode(report)
            guard case let .object(fields) = try JSONDecoder().decode(JSONValue.self, from: data) else { return ["error": .string("not an object")] }
            guard data.count > Event.maximumDetailBytes else { return fields }
            return fields.filter { $0.value.json.count < 4096 }.merging(["truncatedFrom": .number(Double(data.count))]) { $1 }
        } catch {
            return ["error": .string("\(error)")]
        }
    }

    private static let hardware: String = {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }()

    private static var bundleInstance: UUID {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "bundleVersion") == appVersion,
           let instance = defaults.string(forKey: "bundleInstance").flatMap(UUID.init(uuidString:)) {
            return instance
        }
        let instance = UUID()
        defaults.set(appVersion, forKey: "bundleVersion")
        defaults.set(instance.uuidString, forKey: "bundleInstance")
        return instance
    }
}

struct LiveActivity: Identifiable, Equatable {
    let id: String
    let content: LyktaActivity.ContentState
    let state: ObservedState
}

private extension LiveActivity {
    init(_ activity: Activity<LyktaActivity>) {
        self.init(id: activity.id, content: activity.content.state, state: ObservedState(activity.activityState))
    }
}

#if DEBUG
extension Model {
    static func preview(_ phase: Phase, activities: [LiveActivity] = [], areActivitiesEnabled: Bool = true, error: String? = nil) -> Model {
        let model = Model()
        model.phase = phase
        model.activities = activities
        model.areActivitiesEnabled = areActivitiesEnabled
        model.error = error
        return model
    }
}
#endif

private extension ObservedState {
    init(_ state: ActivityState) {
        self = switch state {
        case .pending: .pending
        case .active: .active
        case .stale: .stale
        case .ended: .ended
        case .dismissed: .dismissed
        @unknown default: .unknown
        }
    }
}
