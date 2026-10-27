import Foundation
import LyktaCore

enum Job: Sendable {
    case activity(ActivityJob)
    case notification(NotificationJob)
    case widgets(WidgetJob)
}

struct ActivityJob: Sendable {
    enum Kind: String, Sendable { case start, update, end, deleteChannel }

    let kind: Kind
    let activity: Activity
    let environment: PushEnvironment
    let pushToken: PushToken?
    let tokenMoved: Bool
    let layoutVersion: Version?
}

struct NotificationJob: Sendable {
    let id: UUID
    let deviceID: UUID
    let name: Name
    let request: NotificationRequest
    let environment: PushEnvironment
    let token: PushToken
    let tokenMoved: Bool
    let fetchToken: String
    let expiresAt: Int
}

struct WidgetJob: Sendable {
    let deviceID: UUID
    let generation: Int
    let token: PushToken
    let environment: PushEnvironment
    let tokenMoved: Bool
}

enum Outcome: Sendable {
    case accepted
    case retry(String, throttled: Bool)
    case failed(String, clearsPushToken: Bool)
    case unknown(String)
    case channelGone
    case wrongEnvironment(String)
}

struct Attempt: Sendable {
    let outcome: Outcome
    var detail: [String: JSONValue]
}

struct Delivery: Sendable {
    let store: Store
    let push: any PushService
    let shutdown: Shutdown
    private static let concurrency = 4

    func run() async throws {
        try await store.recover()
        await removeOrphanedChannels()
        try await withThrowingDiscardingTaskGroup { group in
            for tick in 0... {
                guard !shutdown.isRequested else { return }
                let now = Int(Date().timeIntervalSince1970)
                if tick % 240 == 0 { try await store.housekeep(now: now) }
                for job in try await store.claim(now: now, limit: Self.concurrency) {
                    group.addTask {
                        try await store.finish(job, try await send(job, now: now), now: now)
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func send(_ job: Job, now: Int) async throws -> Attempt {
        let id = UUID()
        let clock = ContinuousClock()
        let started = clock.now
        var attempt = switch job {
        case let .activity(job): try await send(job, id: id, now: now)
        case let .notification(job): try await send(job, id: id)
        case let .widgets(job): await send(job, id: id)
        }
        let elapsed = started.duration(to: clock.now).components
        attempt.detail["ms"] = .number((Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15).rounded())
        return attempt
    }

    private func send(_ job: WidgetJob, id: UUID) async -> Attempt {
        var detail: [String: JSONValue] = ["pushID": .string(id.uuidString.lowercased()),
                                           "environment": .string(job.environment.rawValue), "generation": .number(Double(job.generation))]
        guard !shutdown.isRequested else {
            return Attempt(outcome: .retry("The gateway restarted before reloading widgets.", throttled: false), detail: detail)
        }
        do {
            detail["uniqueID"] = try await push.reloadWidgets(deviceToken: job.token, environment: job.environment, id: id).map(JSONValue.string)
            return Attempt(outcome: .accepted, detail: detail)
        } catch {
            return Attempt(outcome: outcome(of: error, sentTo: job.environment, tokenMoved: job.tokenMoved), detail: detail)
        }
    }

    private func send(_ job: NotificationJob, id: UUID) async throws -> Attempt {
        let payload = try job.request.payload(id: job.id, token: job.fetchToken)
        var detail: [String: JSONValue] = [
            "pushID": .string(id.uuidString.lowercased()), "environment": .string(job.environment.rawValue),
            "notification": .string(job.id.uuidString), "name": .string(job.name.rawValue),
            "notificationToken": .string(fingerprint(job.token.description.utf8)), "payloadBytes": .number(Double(payload.count)),
        ]
        do {
            detail["uniqueID"] = try await push.notify(payload, deviceToken: job.token, expiration: job.expiresAt, environment: job.environment, id: id)
                .map(JSONValue.string)
            return Attempt(outcome: .accepted, detail: detail)
        } catch {
            return Attempt(outcome: outcome(of: error, sentTo: job.environment, tokenMoved: job.tokenMoved), detail: detail)
        }
    }

    private func send(_ job: ActivityJob, id: UUID, now: Int) async throws -> Attempt {
        let activity = job.activity
        var detail: [String: JSONValue] = [
            "pushID": .string(id.uuidString.lowercased()), "environment": .string(job.environment.rawValue),
            "revision": .number(Double(activity.revision)), "fingerprint": .string(try activity.fingerprint()),
            "compact": .bool(LyktaActivity.ContentState.isCompact(for: job.layoutVersion)),
        ]
        let outcome: Outcome
        do {
            switch job.kind {
            case .start:
                guard let token = job.pushToken else { return Attempt(outcome: .failed("The phone has no push token.", clearsPushToken: false), detail: detail) }
                detail["pushToStartToken"] = .string(fingerprint(token.description.utf8))
                let channel: String
                if let existing = activity.channel, activity.channelEnvironment == job.environment {
                    channel = existing
                } else {
                    do {
                        channel = try await push.createChannel(environment: job.environment)
                    } catch .unknown {
                        return Attempt(outcome: .retry("Creating the broadcast channel had an unknown outcome.", throttled: false), detail: detail)
                    } catch {
                        return Attempt(outcome: Self.outcome(of: error), detail: detail)
                    }
                    guard try await store.setChannel(channel, environment: job.environment, for: activity.id) else { return Attempt(outcome: .channelGone, detail: detail) }
                    guard !shutdown.isRequested else {
                        return Attempt(outcome: .retry("The gateway restarted before starting the activity.", throttled: false), detail: detail)
                    }
                }
                detail["channel"] = .string(channel)
                let payload = try activity.payload(.start, now: now, channel: channel, layoutVersion: job.layoutVersion)
                detail["payloadBytes"] = .number(Double(payload.count))
                detail["uniqueID"] = try await push.start(payload, deviceToken: token, environment: job.environment, id: id).map(JSONValue.string)
            case .update, .end:
                guard let channel = activity.channel else { return Attempt(outcome: .channelGone, detail: detail) }
                let event: Payload.Event = job.kind == .end ? .end : .update
                let priority = job.kind == .end || activity.alert != nil ? 10 : 5
                let payload = try activity.payload(event, now: now, layoutVersion: job.layoutVersion)
                detail["channel"] = .string(channel)
                detail["priority"] = .number(Double(priority))
                detail["alert"] = .bool(activity.alert != nil)
                detail["payloadBytes"] = .number(Double(payload.count))
                detail["uniqueID"] = try await push.broadcast(payload, channel: channel, priority: priority, environment: job.environment, id: id)
                    .map(JSONValue.string)
            case .deleteChannel:
                guard let channel = activity.channel else { return Attempt(outcome: .accepted, detail: detail) }
                detail["channel"] = .string(channel)
                try await push.deleteChannel(channel, environment: job.environment)
            }
            outcome = .accepted
        } catch let error as APNsError {
            outcome = job.kind == .start ? self.outcome(of: error, sentTo: job.environment, tokenMoved: job.tokenMoved) : Self.outcome(of: error)
        }
        return Attempt(outcome: outcome, detail: detail)
    }

    private func outcome(of error: APNsError, sentTo environment: PushEnvironment, tokenMoved: Bool) -> Outcome {
        if case .rejected(_, "BadDeviceToken") = error, !tokenMoved, push.environments.contains(environment.other) {
            return .wrongEnvironment(error.description)
        }
        return Self.outcome(of: error)
    }

    static func outcome(of error: APNsError) -> Outcome {
        switch error {
        case .notSent: return .retry(error.description, throttled: false)
        case .unknown: return .unknown(error.description)
        case let .rejected(status, reason):
            if status == 429 || status >= 500 || reason == "ExpiredProviderToken" { return .retry(error.description, throttled: status == 429) }
            if reason == "ChannelNotRegistered" { return .channelGone }
            return .failed(error.description, clearsPushToken: ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].contains(reason))
        }
    }

    private func removeOrphanedChannels() async {
        for environment in push.environments {
            do {
                let remote = try await push.channels(environment: environment)
                let known = try await store.channels()
                for channel in remote where !known.contains(channel) {
                    guard !shutdown.isRequested else { return }
                    try await push.deleteChannel(channel, environment: environment)
                }
            } catch {
                log("Removing orphaned \(environment.rawValue) channels failed: \(error)")
            }
        }
    }
}
