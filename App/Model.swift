import ActivityKit
import CryptoKit
import DeviceCheck
import Foundation
import LyktaCore
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
    private(set) var examples: [Example] = []
    private(set) var areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var error: String?

    private let gateway: GatewayClient?
    private let environment: PushEnvironment
    private let telemetry = Telemetry()
    private var credentials: Credentials?
    private var pushToken: PushToken?
    private var syncFailures = 0
    private var runTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?

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
        telemetry.start(launch: launchDetail())
        if case .failed = phase {
            phase = .connecting
        }
        runTask?.cancel()
        runTask = Task { await run() }
    }

    var isRegistered: Bool {
        credentials != nil
    }

    func sceneChanged(to scenePhase: ScenePhase) {
        let name = switch scenePhase {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        telemetry.record("app.scene", ["phase": .string(name)])
        if scenePhase == .active, phase.isReady {
            Task { await sync() }
        }
    }

    func loadExamples() async {
        examples = await Example.bundled(at: .now)
    }

    func copySetup() -> Bool {
        guard let gateway, let credentials else { return false }
        telemetry.record("app.copySetup")
        UIPasteboard.general.string = """
            Show Live Activities on my iPhone with Lykta.
            Gateway: \(gateway.url.absoluteString)
            Token: \(credentials.agentToken)
            Instructions: \(gateway.url.appending(path: "skill/SKILL.md").absoluteString)
            """
        return true
    }

    func show(_ example: Example) async -> Bool {
        guard let gateway, let credentials else { return false }
        telemetry.record("app.example", ["example": .string(example.id)])
        let name = Example.activityName
        let isShowing = Activity<LyktaActivity>.activities.contains { $0.attributes.name == name && [.pending, .active, .stale].contains($0.activityState) }
        return await showingErrors("example") {
            if !isShowing {
                try await gateway.endActivity(name, agentToken: credentials.agentToken)
            }
            try await gateway.putActivity(name, example.request(at: .now), agentToken: credentials.agentToken)
        }
    }

    func send(_ action: Action) async throws {
        guard let gateway, let credentials = try credentials ?? Keychain.load() else {
            throw AppError(status: nil, errorDescription: "Lykta is not connected to a gateway.")
        }
        let detail: [String: JSONValue] = switch action.input {
        case let .button(name): ["button": .string(name)]
        case let .toggle(path, isOn): ["toggle": .string(path), "isOn": .bool(isOn)]
        }
        telemetry.record("activity.action", activity: action.activity, detail)
        do {
            try await gateway.act(action, secret: credentials.deviceSecret)
        } catch {
            telemetry.record("app.error", activity: action.activity, ["operation": .string("action"), "error": .string(error.localizedDescription)])
            throw error
        }
    }

    func reset() async {
        guard let gateway, let credentials else { return }
        runTask?.cancel()
        retryTask?.cancel()
        let deleted = await showingErrors("reset") {
            do {
                try await gateway.deleteDevice(secret: credentials.deviceSecret)
            } catch let error as AppError where error.status == 401 {}
            try Keychain.delete()
        }
        if deleted {
            self.credentials = nil
            telemetry.reset()
            for activity in Activity<LyktaActivity>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            activities = []
            phase = .connecting
            telemetry.record("app.reset")
        }
        start()
    }

    private func run() async {
        guard let gateway else { return }
        let credentials: Credentials
        do {
            if let saved = try Keychain.load() {
                credentials = saved
            } else {
                credentials = try await gateway.register(Registration(environment: environment, appVersion: Self.appVersion, proof: proof(gateway)))
                try Keychain.save(credentials)
                telemetry.record("app.registered")
            }
        } catch {
            telemetry.record("app.error", ["operation": .string("connect"), "error": .string(error.localizedDescription)])
            phase = .failed(error.localizedDescription)
            return
        }
        self.credentials = credentials
        phase = .ready
        telemetry.upload { batch in try await gateway.upload(batch, secret: credentials.deviceSecret) }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observePushTokens() }
            group.addTask { await self.observeActivities() }
            group.addTask { await self.observeAuthorization() }
        }
    }

    private func proof(_ gateway: GatewayClient) async throws -> Registration.Proof {
        if let invite = ProcessInfo.processInfo.environment["LYKTA_INVITE"] {
            return .invite(invite)
        }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw AppError(status: nil, errorDescription: "This device cannot prove Lykta is genuine with App Attest. Launch it with LYKTA_INVITE set to an invite from the gateway.")
        }
        let challenge = try await gateway.challenge()
        let keyID = try await service.generateKey()
        guard let key = Data(base64Encoded: keyID) else {
            throw AppError(status: nil, errorDescription: "App Attest returned an unreadable key identifier.")
        }
        let object = try await service.attestKey(keyID, clientDataHash: Data(SHA256.hash(data: challenge)))
        return .attestation(keyID: key, object: object, challenge: challenge)
    }

    private func observePushTokens() async {
        for await token in Activity<LyktaActivity>.pushToStartTokenUpdates {
            pushToken = PushToken(token)
            telemetry.record("activity.pushToStartToken", ["fingerprint": .string(fingerprint(PushToken(token).description.utf8))])
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
            telemetry.record("activity.vanished", ["activityKitID": .string(id)])
            return
        }
        telemetry.record("activity.observed", activity: activity.attributes.id, Self.describe(activity))
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeState(of: id) }
            group.addTask { await self.observeContent(of: id) }
        }
    }

    private func observeState(of id: String) async {
        guard let activity = Activity<LyktaActivity>.activities.first(where: { $0.id == id }) else { return }
        for await state in activity.activityStateUpdates {
            telemetry.record("activity.state", activity: activity.attributes.id, ["state": .string(ObservedState(state).rawValue)])
            await sync()
        }
    }

    private func observeContent(of id: String) async {
        guard let activity = Activity<LyktaActivity>.activities.first(where: { $0.id == id }) else { return }
        for await content in activity.contentUpdates {
            telemetry.record("activity.content", activity: activity.attributes.id, Self.describe(content))
            activities = Activity<LyktaActivity>.activities.map(LiveActivity.init)
        }
    }

    private func observeAuthorization() async {
        for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
            areActivitiesEnabled = enabled
            telemetry.record("app.authorization", ["activitiesEnabled": .bool(enabled)])
        }
    }

    private func sync() async {
        guard let gateway, let credentials else { return }
        let observed = Activity<LyktaActivity>.activities
        activities = observed.map(LiveActivity.init)
        let deviceReport = DeviceReport(pushToStartToken: pushToken, appVersion: Self.appVersion, layoutVersion: Layout.version,
                                        bundleInstance: Self.bundleInstance,
                                        activities: observed.map { .init(id: $0.attributes.id, state: ObservedState($0.activityState)) })
        retryTask?.cancel()
        do {
            let result = try await gateway.sync(deviceReport, secret: credentials.deviceSecret)
            syncFailures = 0
            error = nil
            for activity in Activity<LyktaActivity>.activities where result.end.contains(activity.attributes.id) {
                telemetry.record("activity.endedByGateway", activity: activity.attributes.id)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        } catch let error as AppError where error.status == 401 {
            guard self.credentials?.deviceSecret == credentials.deviceSecret else { return }
            telemetry.record("app.error", ["operation": .string("sync"), "error": .string(error.localizedDescription)])
            runTask?.cancel()
            phase = .failed("The gateway no longer knows this phone. Reset Lykta to register it again.")
        } catch {
            guard !Task.isCancelled else { return }
            telemetry.record("app.error", ["operation": .string("sync"), "error": .string(error.localizedDescription)])
            self.error = error.localizedDescription
            syncFailures += 1
            let delay = Duration.seconds(min(60, 1 << min(syncFailures, 6)))
            retryTask = Task {
                guard (try? await Task.sleep(for: delay)) != nil else { return }
                retryTask = nil
                await sync()
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
            telemetry.record("app.error", ["operation": .string(operation), "error": .string(error.localizedDescription)])
            self.error = error.localizedDescription
            return false
        }
    }

    private func launchDetail() -> [String: JSONValue] {
        let authorization = ActivityAuthorizationInfo()
        return [
            "appVersion": .string(Self.appVersion), "os": .string(UIDevice.current.systemVersion), "hardware": .string(Self.hardware),
            "environment": .string(environment.rawValue), "applicationState": .string(Self.describe(UIApplication.shared.applicationState)),
            "activitiesEnabled": .bool(authorization.areActivitiesEnabled), "frequentPushesEnabled": .bool(authorization.frequentPushesEnabled),
            "activities": .number(Double(Activity<LyktaActivity>.activities.count)),
        ]
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

extension Model.Phase {
    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

struct LiveActivity: Identifiable, Equatable {
    let id: String
    let attributes: LyktaActivity
    let content: LyktaActivity.ContentState
    let state: ObservedState
}

private extension LiveActivity {
    init(_ activity: Activity<LyktaActivity>) {
        self.init(id: activity.id, attributes: activity.attributes, content: activity.content.state, state: ObservedState(activity.activityState))
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
