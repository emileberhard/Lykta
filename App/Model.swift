import ActivityKit
import Foundation
import LyktaCore
import Observation
import UIKit

@Observable
final class Model {
    enum Phase {
        case unconfigured, connecting, ready
        case failed(String)
    }

    private(set) var phase: Phase
    private(set) var activities: [Activity<LyktaActivity>] = []
    private(set) var areActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var error: String?

    private let gateway: GatewayClient?
    private let environment: PushEnvironment
    private var credentials: Credentials?
    private var pushToken: String?

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

    func run() async {
        guard let gateway else { return }
        do {
            if let saved = try Keychain.load() {
                credentials = saved
            } else {
                let registered = try await gateway.register(Registration(environment: environment, appVersion: Self.appVersion))
                try Keychain.save(registered)
                credentials = registered
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observePushTokens() }
            group.addTask { await self.observeActivities() }
            group.addTask { await self.observeAuthorization() }
        }
    }

    func copySetup() {
        guard let gateway, let credentials else { return }
        UIPasteboard.general.string = """
            Show Live Activities on my iPhone with Lykta.
            Gateway: \(gateway.url.absoluteString)
            Token: \(credentials.agentToken)
            Instructions: \(gateway.url.appending(path: "skill/SKILL.md").absoluteString)
            """
    }

    func sendDemo() async {
        guard let gateway, let credentials else { return }
        await showingErrors {
            try await gateway.putActivity("demo", title: Demo.title, layout: Demo.layout, data: Demo.data(start: .now),
                                          agentToken: credentials.agentToken)
        }
    }

    func reset() async {
        guard let gateway, let credentials else { return }
        await showingErrors {
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

    private func observePushTokens() async {
        for await token in Activity<LyktaActivity>.pushToStartTokenUpdates {
            pushToken = token.map { String(format: "%02x", $0) }.joined()
            await sync()
        }
    }

    private func observeActivities() async {
        await withDiscardingTaskGroup { group in
            for id in Activity<LyktaActivity>.activities.map(\.id) {
                group.addTask { await self.observeState(of: id) }
            }
            await sync()
            for await activity in Activity<LyktaActivity>.activityUpdates {
                let id = activity.id
                group.addTask { await self.observeState(of: id) }
            }
        }
    }

    private func observeState(of id: String) async {
        guard let activity = Activity<LyktaActivity>.activities.first(where: { $0.id == id }) else { return }
        for await _ in activity.activityStateUpdates {
            await sync()
        }
    }

    private func observeAuthorization() async {
        for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates {
            areActivitiesEnabled = enabled
        }
    }

    private func sync() async {
        guard let gateway, let credentials else { return }
        let observed = Activity<LyktaActivity>.activities
        activities = observed
        let deviceReport = DeviceReport(pushToStartToken: pushToken, appVersion: Self.appVersion, bundleInstance: Self.bundleInstance,
                                        activities: observed.map { .init(id: $0.attributes.id.uuidString, state: $0.activityState.name) })
        await showingErrors {
            let result = try await gateway.sync(deviceReport, secret: credentials.deviceSecret)
            for activity in Activity<LyktaActivity>.activities where result.end.contains(activity.attributes.id.uuidString) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        activities = Activity<LyktaActivity>.activities
    }

    private func showingErrors(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static let appVersion: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "") (\(info["CFBundleVersion"] as? String ?? ""))"
    }()

    private static var bundleInstance: String {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "bundleVersion") != appVersion || defaults.string(forKey: "bundleInstance") == nil {
            defaults.set(appVersion, forKey: "bundleVersion")
            defaults.set(UUID().uuidString, forKey: "bundleInstance")
        }
        return defaults.string(forKey: "bundleInstance")!
    }
}

private extension ActivityState {
    var name: String {
        switch self {
        case .active: "active"
        case .stale: "stale"
        case .ended: "ended"
        case .dismissed: "dismissed"
        case .pending: "pending"
        @unknown default: "unknown"
        }
    }
}
