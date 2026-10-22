import Foundation
import LyktaCore

struct Delivery: Sendable {
    let store: Store
    let push: any PushService
    var concurrency = 4

    func run(until shutdown: Shutdown) async throws {
        try await store.recover()
        await removeOrphanedChannels()
        try await withThrowingDiscardingTaskGroup { group in
            for tick in 0... {
                guard !shutdown.isRequested else { return }
                let now = Int(Date().timeIntervalSince1970)
                if tick % 240 == 0 { try await store.housekeep(now: now) }
                for job in try await store.claim(now: now, limit: concurrency) {
                    group.addTask {
                        try await store.finish(job, try await send(job, now: now), now: now)
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func send(_ job: Job, now: Int) async throws -> Attempt {
        let activity = job.activity
        let id = UUID()
        let clock = ContinuousClock()
        let started = clock.now
        var detail: [String: JSONValue] = [
            "pushID": .string(id.uuidString.lowercased()), "environment": .string(job.environment.rawValue),
            "revision": .number(Double(activity.revision)), "fingerprint": .string(try activity.fingerprint()),
        ]
        let outcome: Outcome
        do {
            switch job.kind {
            case .start:
                guard let token = job.pushToken else { return Attempt(outcome: .failed("The phone has no push token.", clearsPushToken: false), detail: detail) }
                detail["pushToStartToken"] = .string(fingerprint(token.description.utf8))
                let channel: String
                if let existing = activity.channel {
                    channel = existing
                } else {
                    do {
                        channel = try await push.createChannel(environment: job.environment)
                    } catch .unknown {
                        return Attempt(outcome: .retry("Creating the broadcast channel had an unknown outcome.", throttled: false), detail: detail)
                    } catch {
                        return Attempt(outcome: Self.outcome(of: error), detail: detail)
                    }
                    try await store.setChannel(channel, for: activity.id)
                }
                detail["channel"] = .string(channel)
                let payload = try activity.payload(.start, now: now, channel: channel, alert: activity.alert)
                detail["payloadBytes"] = .number(Double(payload.count))
                detail["uniqueID"] = try await push.start(payload, deviceToken: token, environment: job.environment, id: id).map(JSONValue.string)
            case .update, .end:
                guard let channel = activity.channel else { return Attempt(outcome: .channelGone, detail: detail) }
                let event: Payload.Event = job.kind == .end ? .end : .update
                let priority = job.kind == .end || activity.alert != nil ? 10 : 5
                let payload = try activity.payload(event, now: now, alert: activity.alert)
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
            outcome = Self.outcome(of: error)
        }
        let elapsed = started.duration(to: clock.now).components
        detail["ms"] = .number((Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15).rounded())
        return Attempt(outcome: outcome, detail: detail)
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
                    try await push.deleteChannel(channel, environment: environment)
                }
            } catch {
                log("Removing orphaned \(environment.rawValue) channels failed: \(error)")
            }
        }
    }
}
