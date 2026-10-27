import ActivityKit
import CryptoKit
import DeviceCheck
import Foundation
import LyktaCore
import Observation
import SwiftUI
import UIKit
import UserNotifications

@Observable
final class Model {
    enum Phase {
        case unconfigured, connecting, ready
        case failed(String)
    }

    private(set) var phase: Phase
    private(set) var activities: [LiveActivity] = []
    private(set) var ending: Set<LiveActivity.ID> = []
    private(set) var examples: [Example] = []
    private(set) var notificationExamples: [NotificationExample] = []
    private(set) var areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var notifications: NotificationSettings?
    private(set) var error: String?

    private let gateway: GatewayClient?
    private let environment: PushEnvironment
    private let telemetry = Telemetry()
    private var credentials: Credentials?
    private var times: [UUID: ActivityTimes] = [:]
    private var pushToken: PushToken?
    private var syncFailures = 0
    private var runTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var registrationObservation: NotificationCenter.ObservationToken?

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let environment = (info["LyktaPushEnvironment"] as? String).flatMap(PushEnvironment.init) else {
            preconditionFailure("Info.plist needs LyktaPushEnvironment")
        }
        let host = info["LyktaGatewayHost"] as? String ?? ""
        self.environment = environment
        gateway = host.isEmpty ? nil : URL(string: "https://\(host)").map(GatewayClient.init)
        phase = gateway == nil ? .unconfigured : .connecting
        registrationObservation = NotificationCenter.default.addObserver(for: NotificationRegistration.self) { [weak self] in
            self?.registered($0)
        }
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
            Task {
                await refreshNotifications()
                await sync()
            }
        }
    }

    func loadExamples() async {
        async let notificationExamples = NotificationExample.bundled()
        examples = await Example.bundled(at: .now)
        self.notificationExamples = await notificationExamples
    }

    func copySetup() async -> Bool {
        guard let gateway, let credentials else { return false }
        telemetry.record("app.copySetup")
        let url = gateway.url.absoluteString
        let script = gateway.url.appending(path: "skill/scripts/lykta").absoluteString
        UIPasteboard.general.string = """
            Show Live Activities and send notifications on my iPhone with Lykta. Set it up and read its instructions with this command:
            curl -fsS --create-dirs -o ~/.local/bin/lykta \(script) && sh ~/.local/bin/lykta setup \(url) \(credentials.agentToken)
            Or in PowerShell:
            irm \(script).ps1 -UseBasicParsing -OutFile $env:TEMP\\lykta.ps1; powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\\lykta.ps1 setup \(url) \(credentials.agentToken)
            """
        await allowNotifications()
        return true
    }

    func allowNotifications() async {
        guard notifications?.authorization == .notDetermined else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            telemetry.record("app.error", ["operation": .string("allowNotifications"), "error": .string(error.localizedDescription)])
        }
        await refreshNotifications()
        await sync()
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

    func send(_ example: NotificationExample) async -> Bool {
        guard let gateway, let credentials else { return false }
        telemetry.record("app.notificationExample", ["example": .string(example.id)])
        return await showingErrors("notificationExample") {
            let token = credentials.agentToken
            let ids = try await withThrowingTaskGroup(of: (String, MediaID).self) { group in
                for (path, medium) in example.media {
                    group.addTask { (path, try await gateway.upload(medium, agentToken: token)) }
                }
                var ids: [String: MediaID] = [:]
                for try await (path, id) in group {
                    ids[path] = id
                }
                return ids
            }
            try await gateway.putNotification("example-\(UUID().uuidString.lowercased())", try example.request(with: ids), agentToken: credentials.agentToken)
        }
    }

    func end(_ activity: LiveActivity) async {
        guard let gateway, let credentials, activity.isEndable, !ending.contains(activity.id) else { return }
        telemetry.record("app.endActivity", activity: activity.attributes.id)
        ending.insert(activity.id)
        let requested = await showingErrors("endActivity") {
            try await gateway.endActivity(activity.attributes.name, agentToken: credentials.agentToken)
        }
        if !requested {
            ending.remove(activity.id)
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
        await refreshNotifications()
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
        telemetry.startUploading { batch in try await gateway.upload(batch, secret: credentials.deviceSecret) }
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
            refreshActivities()
            await sync()
        }
    }

    private func observeAuthorization() async {
        for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
            areActivitiesEnabled = enabled
            telemetry.record("app.authorization", ["activitiesEnabled": .bool(enabled)])
        }
    }

    private func refreshNotifications() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let current = NotificationSettings(authorization: .init(settings.authorizationStatus), alertStyle: .init(settings.alertStyle),
                                           registration: notifications?.registration ?? .pending)
        if current.token == nil, [.authorized, .provisional, .ephemeral].contains(current.authorization) {
            UIApplication.shared.registerForRemoteNotifications()
        }
        guard current != notifications else { return }
        notifications = current
        telemetry.record("app.notifications", ["authorization": .string(current.authorization.rawValue), "alertStyle": .string(current.alertStyle.rawValue)])
    }

    private func registered(_ result: NotificationRegistration) {
        guard let current = notifications else { return }
        let registration: NotificationSettings.Registration
        switch result {
        case let .registered(token):
            guard current.token != token else { return }
            telemetry.record("app.notificationToken", ["fingerprint": .string(fingerprint(token.description.utf8))])
            registration = .registered(token)
        case let .failed(error):
            telemetry.record("app.error", ["operation": .string("registerForNotifications"), "error": .string(error)])
            registration = .failed(String(error.prefix(NotificationSettings.maximumRegistrationErrorLength)))
        }
        notifications = NotificationSettings(authorization: current.authorization, alertStyle: current.alertStyle, registration: registration)
        Task { await sync() }
    }

    private func sync() async {
        guard let gateway, let credentials, let notifications else { return }
        let observed = Activity<LyktaActivity>.activities
        refreshActivities()
        let deviceReport = DeviceReport(pushToStartToken: pushToken, appVersion: Self.appVersion, layoutVersion: Layout.version,
                                        bundleInstance: Self.bundleInstance,
                                        activities: observed.map { .init(id: $0.attributes.id, state: ObservedState($0.activityState)) },
                                        notifications: notifications)
        retryTask?.cancel()
        do {
            let result = try await gateway.sync(deviceReport, secret: credentials.deviceSecret)
            syncFailures = 0
            error = nil
            times = Dictionary(result.activities.map { ($0.id, $0) }) { $1 }
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
        refreshActivities()
    }

    private func refreshActivities() {
        activities = Activity<LyktaActivity>.activities.map { LiveActivity($0, times: times[$0.attributes.id]) }
        ending.formIntersection(activities.filter(\.isEndable).map(\.id))
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
    let times: ActivityTimes?

    var isEndable: Bool {
        [.pending, .active, .stale].contains(state)
    }
}

private extension LiveActivity {
    init(_ activity: Activity<LyktaActivity>, times: ActivityTimes?) {
        self.init(id: activity.id, attributes: activity.attributes, content: activity.content.state, state: ObservedState(activity.activityState), times: times)
    }
}

#if DEBUG
extension Model {
    static func preview(_ phase: Phase, activities: [LiveActivity] = [], ending: Set<LiveActivity.ID> = [], areActivitiesEnabled: Bool = true,
                        notifications: NotificationSettings = NotificationSettings(authorization: .authorized, alertStyle: .alert, registration: .pending)) -> Model {
        let model = Model()
        model.phase = phase
        model.activities = activities
        model.ending = ending
        model.areActivitiesEnabled = areActivitiesEnabled
        model.notifications = notifications
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

private extension NotificationSettings.Authorization {
    init(_ status: UNAuthorizationStatus) {
        self = switch status {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        case .denied: .denied
        @unknown default: .denied
        }
    }
}

private extension NotificationSettings.AlertStyle {
    init(_ style: UNAlertStyle) {
        self = switch style {
        case .none: .none
        case .alert: .alert
        case .banner: .banner
        @unknown default: .banner
        }
    }
}
