import Foundation

struct Delivery: Sendable {
    let store: Store
    let push: any PushService
    var concurrency = 4

    func run() async throws {
        try await store.recover()
        await removeOrphanedChannels()
        try await withThrowingDiscardingTaskGroup { group in
            for tick in 0... {
                let now = Int(Date().timeIntervalSince1970)
                if tick % 240 == 0 { try await store.housekeep(now: now) }
                for job in try await store.claim(now: now, limit: concurrency) {
                    group.addTask {
                        let outcome = try await send(job, now: now)
                        try await store.finish(job, outcome, now: now)
                    }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func send(_ job: Job, now: Int) async throws -> Outcome {
        let activity = job.activity
        do {
            switch job.kind {
            case .start:
                guard let token = job.pushToken else { return .failed("The phone has no push token.", clearsPushToken: false) }
                let channel: String
                if let existing = activity.channel {
                    channel = existing
                } else {
                    do {
                        channel = try await push.createChannel(environment: job.environment)
                    } catch .unknown {
                        return .retry("Creating the broadcast channel had an unknown outcome.", throttled: false)
                    } catch {
                        return Self.outcome(of: error)
                    }
                    try await store.setChannel(channel, for: activity.id)
                }
                let payload = try activity.payload("start", now: now, channel: channel, alert: activity.alert)
                try await push.start(payload, deviceToken: token, environment: job.environment)
            case .update, .end:
                guard let channel = activity.channel else { return .channelGone }
                let event = job.kind == .end ? "end" : "update"
                let priority = job.kind == .end || activity.alert != nil ? 10 : 5
                try await push.broadcast(try activity.payload(event, now: now, alert: activity.alert), channel: channel,
                                         priority: priority, environment: job.environment)
            case .deleteChannel:
                guard let channel = activity.channel else { return .accepted }
                try await push.deleteChannel(channel, environment: job.environment)
            }
            return .accepted
        } catch let error as APNsError {
            return Self.outcome(of: error)
        }
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
