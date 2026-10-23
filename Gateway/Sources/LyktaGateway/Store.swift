import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LyktaCore

extension PushToken: SQLBindable {
    var sqlValue: SQLValue { .text(description) }
}

extension PushEnvironment: SQLBindable {}
extension ObservedState: SQLBindable {}
extension DeliveryState: SQLBindable {}
extension ActivityName: SQLBindable {}
extension Activity.Phase: SQLBindable {}

extension ActionRecord {
    init(_ row: Row) throws {
        seq = try row.integer("seq")
        activity = try row.text("name", as: ActivityName.init(rawValue:))
        input = if let button = try row.optionalString("button") {
            .button(button)
        } else {
            .toggle(try row.string("toggle"), isOn: try row.integer("is_on") != 0)
        }
        at = Date(timeIntervalSince1970: Double(try row.integer("at")))
    }
}

extension StoredEvent {
    init(_ row: Row) throws {
        seq = try row.integer("seq")
        device = try row.text("device_id", as: UUID.init(uuidString:))
        activity = try row.optionalText("activity_id", as: UUID.init(uuidString:))
        source = try row.string("source")
        name = try row.string("name")
        at = Date(timeIntervalSince1970: Double(try row.integer("at")) / 1000)
        receivedAt = Date(timeIntervalSince1970: Double(try row.integer("received_at")) / 1000)
        detail = try JSONDecoder().decode(JSONValue.self, from: Data(try row.string("detail").utf8))
    }
}

actor Store {
    static let maximumAttempts = 5
    static let maximumPayloadBytes = 4096
    static let eventRetention = 14 * 86400
    static let maximumEventBytesPerDevice = 8 << 20
    static let actionRetention = 86400
    static let maximumActionsPerDevice = 1000
    static let inviteLifetime = 3600

    private let db: Database
    private let maximumDevices: Int
    private let maximumLiveActivities: Int

    init(path: String, maximumDevices: Int, maximumLiveActivities: Int) throws {
        let db = try Database(path: path)
        try Schema.migrate(db)
        self.db = db
        self.maximumDevices = maximumDevices
        self.maximumLiveActivities = maximumLiveActivities
    }

    static func backup(_ database: String, to path: String) throws {
        guard FileManager.default.fileExists(atPath: database) else { throw ConfigurationError("There is no database at \(database).") }
        try Database(path: database).run("VACUUM INTO ?", path)
    }

    // MARK: Devices

    func registerDevice(environment: PushEnvironment, appVersion: String, admission: Admission, now: Int) throws -> Credentials {
        try db.transaction {
            guard try count(db.query("SELECT count(*) AS n FROM devices")) < maximumDevices else {
                throw APIError(.registrationClosed, "This gateway accepts no more devices.")
            }
            let attestationKey: String?
            switch admission {
            case let .attested(keyID):
                attestationKey = keyID.base64EncodedString()
                guard try db.query("SELECT 1 FROM devices WHERE attestation_key = ?", attestationKey).isEmpty else {
                    throw APIError(.registrationRefused, "This App Attest key already registered a device.")
                }
            case let .invited(code):
                attestationKey = nil
                guard try !db.query("SELECT 1 FROM invites WHERE hash = ? AND expires_at > ?", Self.hash(code), now).isEmpty else {
                    throw APIError(.registrationRefused, "The invite is unknown, used or expired.")
                }
                try db.run("DELETE FROM invites WHERE hash = ?", Self.hash(code))
            }
            let id = UUID()
            let secret = Self.token("lykta_device_")
            let agentToken = Self.token("lykta_agent_")
            try db.run("""
                INSERT INTO devices (id, secret_hash, agent_hash, environment, app_version, attestation_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, id, Self.hash(secret), Self.hash(agentToken), environment, appVersion, attestationKey, now)
            try record("device.registered", device: id, activity: nil, [
                "environment": .string(environment.rawValue), "appVersion": .string(appVersion),
                "admission": .string(attestationKey == nil ? "invite" : "attestation"),
            ])
            return Credentials(deviceSecret: secret, agentToken: agentToken)
        }
    }

    func invite(now: Int) throws -> String {
        let code = Self.token("lykta_invite_")
        try db.run("INSERT INTO invites (hash, expires_at) VALUES (?, ?)", Self.hash(code), now + Self.inviteLifetime)
        return code
    }

    func device(secret: String) throws -> Device? {
        try device(column: "secret_hash", hash: Self.hash(secret))
    }

    func device(agentToken: String) throws -> Device? {
        try device(column: "agent_hash", hash: Self.hash(agentToken))
    }

    func sync(_ device: Device, report: DeviceReport, now: Int) throws -> [UUID] {
        try db.transaction {
            let previous = try db.query("SELECT bundle_instance FROM devices WHERE id = ?", device.id).first?
                .optionalText("bundle_instance", as: UUID.init(uuidString:))
            try db.run("UPDATE devices SET push_token = COALESCE(?, push_token), app_version = ?, layout_version = ?, bundle_instance = ? WHERE id = ?",
                       report.pushToStartToken, report.appVersion, report.layoutVersion?.description, report.bundleInstance, device.id)
            let reported = Set(report.activities.map(\.id))
            let isNewInstall = previous != nil && previous != report.bundleInstance
            var abandoned: [JSONValue] = []
            if isNewInstall {
                for row in try db.query("SELECT id FROM activities WHERE device_id = ? AND phase != 'ended'", device.id) {
                    let id = try row.text("id", as: UUID.init(uuidString:))
                    guard !reported.contains(id) else { continue }
                    try db.run("UPDATE activities SET phase = 'ended', ended_at = ?, error = 'The app was reinstalled or updated.' WHERE id = ?", now, id)
                    abandoned.append(.string(id.uuidString))
                }
            }
            var tombstones: [UUID] = []
            for observed in report.activities {
                guard let phase = try db.query("SELECT phase FROM activities WHERE id = ? AND device_id = ?", observed.id, device.id).first?
                    .text("phase", as: Activity.Phase.init(rawValue:)) else { continue }
                let gone = [.ended, .dismissed].contains(observed.state)
                try db.run("""
                    UPDATE activities SET device_state = ?, phase = CASE WHEN ? THEN 'ended' ELSE phase END,
                      ended_at = CASE WHEN ? THEN COALESCE(ended_at, ?) ELSE ended_at END WHERE id = ?
                    """, observed.state, gone, gone, now, observed.id)
                if phase == .ended, !gone { tombstones.append(observed.id) }
            }
            let token = switch report.pushToStartToken {
            case nil: "none"
            case device.pushToken: "unchanged"
            case let .some(token): "new \(fingerprint(token.description.utf8))"
            }
            try record("device.sync", device: device.id, activity: nil, [
                "appVersion": .string(report.appVersion),
                "layoutVersion": report.layoutVersion.map { .string($0.description) } ?? .null,
                "install": .string(report.bundleInstance.uuidString),
                "newInstall": .bool(isNewInstall),
                "pushToStartToken": .string(token),
                "activities": .array(report.activities.map { .object(["id": .string($0.id.uuidString), "state": .string($0.state.rawValue)]) }),
                "endedByReinstall": .array(abandoned),
                "toldToEnd": .array(tombstones.map { .string($0.uuidString) }),
            ])
            return tombstones
        }
    }

    func deleteDevice(_ device: Device) throws {
        try db.run("DELETE FROM devices WHERE id = ?", device.id)
    }

    // MARK: Activities

    func put(_ device: Device, name: ActivityName, request: ActivityRequest, now: Int) throws -> ActivityStatus {
        try db.transaction {
            let current = try liveActivity(device, name: name)
            if let expected = request.ifRevision, current?.revision != expected {
                throw APIError(.conflict, "The activity is no longer at revision \(expected). Read it again, then send your change.")
            }
            guard let title = request.title ?? current?.title, let layout = try request.layout ?? current.map({ try decode($0.layout) }) else {
                throw APIError(.invalidRequest, "Starting an activity needs a title and a layout.")
            }
            let data = try request.data ?? current.map { try decode($0.data) } ?? .object([:])
            let state = try Self.content(title: title, layout: layout, data: data)
            try Self.admit(state, on: device)
            let content = try Self.encoded(state)
            let alert = try request.alert.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            let staleAfter = request.staleAfter ?? current?.staleAfter
            let relevance = request.relevance ?? current?.relevance
            let endsAt = request.endAfter.map { now + $0 } ?? current?.endsAt
            let id: UUID
            if let current {
                id = current.id
                let changed = try title != current.title || layout != decode(current.layout) || data != decode(current.data) || alert != nil
                    || request.staleAfter != nil || relevance != current.relevance || endsAt != current.endsAt
                if changed {
                    try db.run("""
                        UPDATE activities SET title = ?, layout = ?, data = ?, content = ?, stale_after = ?, ends_at = ?, relevance = ?,
                          alert = COALESCE(?, alert), revision = revision + 1 WHERE id = ?
                        """, title, Self.text(layout), Self.text(data), content, staleAfter, endsAt, relevance, alert, id)
                }
            } else {
                guard device.pushToken != nil else {
                    throw APIError(.deviceNotReady, "The phone has not shared its push token yet. Open Lykta on the phone.")
                }
                let live = try count(db.query("SELECT count(*) AS n FROM activities WHERE device_id = ? AND phase IN ('starting', 'live')", device.id))
                guard live < maximumLiveActivities else {
                    throw APIError(.tooManyActivities, "End an activity before starting another; the limit is \(maximumLiveActivities).")
                }
                id = UUID()
                try db.run("""
                    INSERT INTO activities (id, device_id, name, phase, title, layout, data, content, stale_after, ends_at, relevance, alert,
                      revision, delivery, created_at) VALUES (?, ?, ?, 'starting', ?, ?, ?, ?, ?, ?, ?, ?, 1, 'pending', ?)
                    """, id, device.id, name, title, Self.text(layout), Self.text(data), content, staleAfter, endsAt, relevance, alert, now)
            }
            let activity = try self.activity(id)
            let size = try Self.payloadSize(of: activity, now: now)
            try record("activity.put", device: device.id, activity: id, [
                "name": .string(name.rawValue), "created": .bool(current == nil), "revision": .number(Double(activity.revision)),
                "fingerprint": .string(try activity.fingerprint()), "payloadBytes": .number(Double(size)), "alert": .bool(request.alert != nil),
                "endsAt": activity.endsAt.map { .number(Double($0)) } ?? .null,
            ])
            return activity.status
        }
    }

    func end(_ device: Device, name: ActivityName, dismissAfter: Int?, now: Int) throws -> ActivityStatus {
        try db.transaction {
            guard let current = try liveActivity(device, name: name) else {
                throw APIError(.notFound, "No live activity is named \(name).")
            }
            return try end(current, dismissAt: dismissAfter.map { now + $0 }, now: now,
                           ["dismissAfter": dismissAfter.map { .number(Double($0)) } ?? .null]).status
        }
    }

    func detail(_ device: Device, name: ActivityName) throws -> ActivityDetail {
        guard let row = try db.query("SELECT * FROM activities WHERE device_id = ? AND name = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                                     device.id, name).first else {
            throw APIError(.notFound, "No activity is named \(name).")
        }
        let activity = try Activity(row)
        return ActivityDetail(status: try status(of: activity, observations: observations(device, of: [activity])), data: try decode(activity.data))
    }

    func list(_ device: Device) throws -> [ActivityStatus] {
        let activities = try db.query("SELECT * FROM activities WHERE device_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 100", device.id)
            .map(Activity.init)
        let observations = try observations(device, of: activities)
        return try activities.map { try status(of: $0, observations: observations) }
    }

    private func observations(_ device: Device, of activities: [Activity]) throws -> [UUID: [String: Bool]] {
        let rows = try db.query("""
            SELECT activity_id, json_extract(detail, '$.fingerprint') AS fingerprint, json_extract(detail, '$.layoutReadable') AS readable, max(seq)
              FROM events WHERE device_id = ? AND source = 'app' AND name IN ('activity.observed', 'activity.content')
                AND activity_id IN (SELECT value FROM json_each(?))
                AND json_type(detail, '$.fingerprint') = 'text' AND json_type(detail, '$.layoutReadable') IN ('true', 'false')
              GROUP BY activity_id, fingerprint
            """, device.id, String(decoding: try JSONEncoder().encode(activities.map(\.id.uuidString)), as: UTF8.self))
        var observations: [UUID: [String: Bool]] = [:]
        for row in rows {
            observations[try row.text("activity_id", as: UUID.init(uuidString:)), default: [:]][try row.string("fingerprint")] = try row.integer("readable") != 0
        }
        return observations
    }

    private func status(of activity: Activity, observations: [UUID: [String: Bool]]) throws -> ActivityStatus {
        guard let observed = observations[activity.id] else { return activity.status }
        return activity.status(layoutReadable: observed[try activity.fingerprint()])
    }

    // MARK: Actions

    func act(_ device: Device, _ action: Action, now: Int) throws {
        try db.transaction {
            guard try db.query("SELECT 1 FROM actions WHERE id = ?", action.id).isEmpty else { return }
            guard let row = try db.query("SELECT * FROM activities WHERE id = ? AND device_id = ? AND phase IN ('starting', 'live')",
                                         action.activity, device.id).first else {
                throw APIError(.notFound, "The activity has ended.")
            }
            let activity = try Activity(row)
            let layout = try JSONDecoder().decode(LyktaActivity.ContentState.self, from: Data(activity.content.utf8)).layout
            var detail: [String: JSONValue] = ["name": .string(activity.name.rawValue)]
            let data = try decode(activity.data)
            let changed: JSONValue
            switch action.input {
            case let .button(name):
                guard let effects = layout?.buttons[name] else { throw APIError(.conflict, "The activity no longer shows the button \(name).") }
                changed = try Self.pressing { () throws(LayoutError) in try effects.applied(to: data, at: Date(timeIntervalSince1970: TimeInterval(now))) }
                try db.run("INSERT INTO actions (id, device_id, activity_id, button, at) VALUES (?, ?, ?, ?, ?)",
                           action.id, device.id, activity.id, name, now)
                detail["button"] = .string(name)
            case let .toggle(path, isOn):
                guard layout?.toggles[path] != nil else { throw APIError(.conflict, "The activity no longer shows the toggle \(path).") }
                changed = try Self.pressing { () throws(LayoutError) in try data.replacing(path, with: .bool(isOn)) }
                try db.run("INSERT INTO actions (id, device_id, activity_id, toggle, is_on, at) VALUES (?, ?, ?, ?, ?, ?)",
                           action.id, device.id, activity.id, path, isOn, now)
                detail["toggle"] = .string(path)
                detail["isOn"] = .bool(isOn)
            }
            if changed != data {
                let template = try decode(activity.layout)
                let state = try Self.pressing { () throws(LayoutError) in
                    try LyktaActivity.ContentState(title: activity.title, layout: template.filled(with: changed).json)
                }
                try Self.admit(state, on: device)
                try db.run("UPDATE activities SET data = ?, content = ?, revision = revision + 1 WHERE id = ?", Self.text(changed), Self.encoded(state), activity.id)
                _ = try Self.payloadSize(of: self.activity(activity.id), now: now)
            }
            detail["revision"] = .number(Double(try self.activity(activity.id).revision))
            try record("activity.action", device: device.id, activity: activity.id, detail)
        }
    }

    func actions(_ device: Device, after: Int64, limit: Int) throws -> [ActionRecord] {
        try db.query("""
            SELECT x.seq, x.button, x.toggle, x.is_on, x.at, a.name FROM actions x JOIN activities a ON a.id = x.activity_id
              WHERE x.device_id = ? AND x.seq > ? ORDER BY x.seq LIMIT ?
            """, device.id, after, limit).map(ActionRecord.init)
    }

    func latestAction(_ device: Device) throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(seq), 0) AS seq FROM actions WHERE device_id = ?", device.id)[0].integer("seq")
    }

    // MARK: Delivery

    func recover() throws {
        try db.execute("""
            UPDATE activities SET phase = 'live', delivery = 'unknown', error = 'The gateway restarted while starting this activity.'
              WHERE in_flight = 1 AND phase = 'starting' AND channel IS NOT NULL;
            UPDATE activities SET in_flight = 0;
            """)
    }

    func housekeep(now: Int) throws {
        try db.transaction {
            for row in try db.query("SELECT id, device_id FROM activities WHERE phase != 'ended' AND in_flight = 0 AND created_at <= ?", now - 8 * 3600) {
                let id = try row.text("id", as: UUID.init(uuidString:))
                try db.run("""
                    UPDATE activities SET phase = 'ended', ended_at = ?, error = COALESCE(error, 'Live Activities last at most 8 hours.') WHERE id = ?
                    """, now, id)
                try record("activity.expired", device: try row.text("device_id", as: UUID.init(uuidString:)), activity: id, [:])
            }
            for row in try db.query("""
                SELECT id, device_id FROM activities a WHERE phase = 'live' AND delivery = 'accepted' AND device_state IS NULL
                  AND created_at <= ? AND NOT EXISTS (SELECT 1 FROM events WHERE activity_id = a.id AND name = 'activity.unseen')
                """, now - 60) {
                try record("activity.unseen", device: try row.text("device_id", as: UUID.init(uuidString:)),
                           activity: try row.text("id", as: UUID.init(uuidString:)),
                           ["reason": .string("""
                               Apple accepted the start over a minute ago, but the phone has not reported the activity. \
                               iOS drops starts when the app's push-to-start budget is spent or Live Activities are off.
                               """)])
            }
        }
        try db.run("DELETE FROM activities WHERE phase = 'ended' AND channel IS NULL AND ended_at <= ?", now - 7 * 86400)
        try db.run("DELETE FROM actions WHERE at < ?", now - Self.actionRetention)
        try db.run("DELETE FROM invites WHERE expires_at <= ?", now)
        try db.run("""
            DELETE FROM actions WHERE seq IN (SELECT seq FROM (
              SELECT seq, ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY seq DESC) AS n FROM actions) WHERE n > ?)
            """, Self.maximumActionsPerDevice)
        try db.run("DELETE FROM events WHERE received_at < ?", Int64(now - Self.eventRetention) * 1000)
        try db.run("""
            DELETE FROM events WHERE seq IN (SELECT seq FROM (
              SELECT seq, SUM(bytes) OVER (PARTITION BY device_id ORDER BY seq DESC) AS total FROM events) WHERE total > ?)
            """, Self.maximumEventBytesPerDevice)
    }

    // MARK: Events

    func ingest(_ device: Device, _ batch: EventBatch) throws {
        let receivedAt = Self.milliseconds(.now)
        try db.transaction {
            for event in batch.events {
                let detail = String(decoding: event.detail.json, as: UTF8.self)
                try db.run("""
                    INSERT OR IGNORE INTO events (id, device_id, activity_id, source, name, at, received_at, bytes, detail)
                      VALUES (?, ?, ?, 'app', ?, ?, ?, ?, ?)
                    """, event.id, device.id, event.activity, event.name, Self.milliseconds(event.at), receivedAt, detail.utf8.count, detail)
            }
        }
    }

    func events(device: UUID?, after: Int64?, limit: Int) throws -> [StoredEvent] {
        if let after, after > (try db.query("SELECT COALESCE(MAX(seq), 0) AS seq FROM sqlite_sequence WHERE name = 'events'")[0].integer("seq")) {
            throw APIError(.invalidRequest, "after is newer than the newest event; read without after to start again.")
        }
        let rows = if let after {
            try db.query("SELECT * FROM events WHERE (?1 IS NULL OR device_id = ?1) AND seq > ?2 ORDER BY seq LIMIT ?3", device, after, limit)
        } else {
            Array(try db.query("SELECT * FROM events WHERE (?1 IS NULL OR device_id = ?1) ORDER BY seq DESC LIMIT ?2", device, limit).reversed())
        }
        return try rows.map(StoredEvent.init)
    }

    func recordFailure(token: String, request: String, _ error: APIError) throws {
        guard let device = try device(column: "agent_hash", hash: Self.hash(token)) ?? device(column: "secret_hash", hash: Self.hash(token)) else {
            return
        }
        try record("request.failed", device: device.id, activity: nil, [
            "request": .string(request), "status": .number(Double(error.code.status)),
            "error": .string(error.code.rawValue), "message": .string(error.message),
        ])
    }

    func claim(now: Int, limit: Int) throws -> [Job] {
        try db.transaction {
            for row in try db.query("SELECT * FROM activities WHERE phase IN ('starting', 'live') AND ends_at <= ?", now) {
                _ = try end(Activity(row), dismissAt: now, now: now, ["dismissAfter": .number(0), "scheduled": .bool(true)])
            }
            let free = limit - (try count(db.query("SELECT count(*) AS n FROM activities WHERE in_flight = 1")))
            guard free > 0 else { return [] }
            let rows = try db.query("""
                SELECT a.*, d.environment, d.push_token FROM activities a JOIN devices d ON d.id = a.device_id
                WHERE a.in_flight = 0 AND a.retry_at <= ?1 AND (
                  (a.phase = 'starting' AND d.push_token IS NOT NULL)
                  OR (a.phase = 'live' AND a.revision > a.sent_revision AND a.last_sent_at < ?1)
                  OR (a.phase = 'ending' AND a.last_sent_at < ?1)
                  OR (a.phase = 'ended' AND a.channel IS NOT NULL AND a.ended_at <= ?1 - 300))
                ORDER BY a.retry_at, a.last_sent_at LIMIT ?2
                """, now, free)
            return try rows.map { row in
                let activity = try Activity(row)
                try db.run("UPDATE activities SET in_flight = 1, last_sent_at = ?, alert = NULL WHERE id = ?", now, activity.id)
                let kind: Job.Kind = switch activity.phase {
                case .starting: .start
                case .live: .update
                case .ending: .end
                case .ended: .deleteChannel
                }
                return Job(kind: kind, activity: activity, environment: try row.text("environment", as: PushEnvironment.init(rawValue:)),
                           pushToken: try row.optionalText("push_token", as: PushToken.init(hex:)))
            }
        }
    }

    func setChannel(_ channel: String, for activityID: UUID) throws -> Bool {
        try db.run("UPDATE activities SET channel = ? WHERE id = ?", channel, activityID)
        return try !db.query("SELECT 1 FROM activities WHERE id = ?", activityID).isEmpty
    }

    func channels() throws -> Set<String> {
        Set(try db.query("SELECT channel FROM activities WHERE channel IS NOT NULL").map { try $0.string("channel") })
    }

    func finish(_ job: Job, _ attempt: Attempt, now: Int) throws {
        var outcome = attempt.outcome
        if case let .unknown(error) = outcome, job.kind != .start { outcome = .retry(error, throttled: false) }
        if case let .retry(error, _) = outcome, job.activity.failures + 1 >= Self.maximumAttempts {
            outcome = .failed(error, clearsPushToken: false)
        }
        let id = job.activity.id
        let revision = job.activity.revision
        try db.transaction {
            guard try !db.query("SELECT 1 FROM activities WHERE id = ?", id).isEmpty else { return }
            let (result, error): (String, String?) = switch outcome {
            case .accepted: ("accepted", nil)
            case let .retry(error, throttled): (throttled ? "throttled" : "retry", error)
            case let .failed(error, _): ("failed", error)
            case let .unknown(error): ("unknown", error)
            case .channelGone: ("channelGone", nil)
            }
            try record("push.\(job.kind.rawValue)", device: job.activity.deviceID, activity: id,
                       attempt.detail.merging(["outcome": .string(result), "error": error.map(JSONValue.string) ?? .null]) { $1 })
            switch (job.kind, outcome) {
            case let (_, .retry(error, throttled)):
                let alert = try job.activity.alert.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
                try db.run("""
                    UPDATE activities SET retry_at = ?, failures = failures + 1, delivery = ?, error = ?, alert = COALESCE(alert, ?) WHERE id = ?
                    """, now + min(1 << (job.activity.failures + 1), 300), throttled ? DeliveryState.throttled : .pending, error, alert, id)
            case (.deleteChannel, _):
                try db.run("UPDATE activities SET channel = NULL WHERE id = ?", id)
            case (.start, .accepted):
                try db.run("""
                    UPDATE activities SET phase = CASE phase WHEN 'starting' THEN 'live' ELSE phase END, delivery = 'accepted',
                      sent_revision = ?, failures = 0, error = NULL WHERE id = ?
                    """, revision, id)
            case let (.start, .unknown(error)):
                try db.run("""
                    UPDATE activities SET phase = CASE phase WHEN 'starting' THEN 'live' ELSE phase END, delivery = 'unknown',
                      sent_revision = ?, error = ? WHERE id = ?
                    """, revision, error, id)
            case (.update, .accepted):
                try db.run("UPDATE activities SET delivery = 'accepted', sent_revision = ?, failures = 0, error = NULL WHERE id = ?", revision, id)
            case let (.update, .failed(error, _)):
                try db.run("UPDATE activities SET delivery = 'failed', sent_revision = ?, failures = 0, error = ? WHERE id = ?", revision, error, id)
            case (.end, .accepted):
                try db.run("UPDATE activities SET phase = 'ended', ended_at = ?, delivery = 'accepted', error = NULL WHERE id = ?", now, id)
            case let (.start, .failed(error, clearsPushToken)), let (.end, .failed(error, clearsPushToken)):
                try db.run("UPDATE activities SET phase = 'ended', ended_at = ?, delivery = 'failed', error = ? WHERE id = ?", now, error, id)
                if clearsPushToken {
                    try db.run("UPDATE devices SET push_token = NULL WHERE id = (SELECT device_id FROM activities WHERE id = ?)", id)
                }
            case (_, .channelGone):
                try db.run("""
                    UPDATE activities SET phase = 'ended', ended_at = COALESCE(ended_at, ?), channel = NULL,
                      error = 'The broadcast channel no longer exists.' WHERE id = ?
                    """, now, id)
            case (_, .unknown):
                preconditionFailure("unknown outcomes of non-start jobs are retried")
            }
            try db.run("UPDATE activities SET in_flight = 0 WHERE id = ?", id)
        }
    }

    // MARK: Helpers

    private static func content(title: String, layout: JSONValue, data: JSONValue) throws -> LyktaActivity.ContentState {
        do {
            return try LyktaActivity.ContentState(title: title, layout: layout.filled(with: data).json)
        } catch let error as LayoutError {
            throw APIError(.invalidLayout, error.description)
        }
    }

    private static func pressing<T>(_ change: () throws(LayoutError) -> T) throws(APIError) -> T {
        do {
            return try change()
        } catch {
            throw APIError(.conflict, "The press cannot change the data: \(error)")
        }
    }

    private static func encoded(_ state: LyktaActivity.ContentState) throws -> String {
        String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
    }

    private static func admit(_ state: LyktaActivity.ContentState, on device: Device) throws {
        guard let requirement = state.layout?.requirement else { return }
        let phone = device.layoutVersion ?? Version(leading: device.appVersion)
        if let phone, phone >= requirement.version { return }
        let draws = if let layoutVersion = device.layoutVersion {
            "this phone's Lykta app draws layouts up to \(layoutVersion)"
        } else if phone != nil {
            "this phone runs Lykta \(device.appVersion)"
        } else {
            "this phone's Lykta version (\(device.appVersion)) is unknown"
        }
        throw APIError(.appUpdateRequired, "\(requirement.path) uses \(requirement.feature), which needs Lykta \(requirement.version) or later, and \(draws). "
                       + "Ask the user to update Lykta and open it once, or send the layout without it.")
    }

    private static func payloadSize(of activity: Activity, now: Int) throws -> Int {
        let size = try activity.payload(activity.phase == .starting ? .start : .update, now: now,
                                        channel: String(repeating: "x", count: 64)).count
        guard size <= maximumPayloadBytes else {
            throw APIError(.payloadTooLarge,
                           "The push payload would be \(size) bytes; APNs allows \(maximumPayloadBytes). Simplify the layout or shorten its text.")
        }
        return size
    }

    private func end(_ activity: Activity, dismissAt: Int?, now: Int, _ detail: [String: JSONValue]) throws -> Activity {
        try db.run("""
            UPDATE activities SET phase = CASE WHEN phase = 'starting' AND in_flight = 0 THEN 'ended' ELSE 'ending' END,
              ended_at = CASE WHEN phase = 'starting' AND in_flight = 0 THEN ? END, dismiss_at = ?, retry_at = 0, failures = 0
              WHERE id = ?
            """, now, dismissAt, activity.id)
        let ended = try self.activity(activity.id)
        try record("activity.end", device: ended.deviceID, activity: ended.id,
                   detail.merging(["name": .string(ended.name.rawValue), "phase": .string(ended.phase.rawValue)]) { $1 })
        return ended
    }

    private func record(_ name: String, device: UUID, activity: UUID?, _ detail: [String: JSONValue]) throws {
        let now = Self.milliseconds(.now)
        let json = String(decoding: JSONValue.object(detail).json, as: UTF8.self)
        try db.run("""
            INSERT INTO events (id, device_id, activity_id, source, name, at, received_at, bytes, detail)
              VALUES (?, ?, ?, 'gateway', ?, ?, ?, ?, ?)
            """, UUID(), device, activity, name, now, now, json.utf8.count, json)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func device(column: String, hash: String) throws -> Device? {
        guard let row = try db.query("SELECT id, environment, push_token, app_version, layout_version FROM devices WHERE \(column) = ?", hash).first else {
            return nil
        }
        return Device(id: try row.text("id", as: UUID.init(uuidString:)),
                      environment: try row.text("environment", as: PushEnvironment.init(rawValue:)),
                      pushToken: try row.optionalText("push_token", as: PushToken.init(hex:)),
                      appVersion: try row.string("app_version"),
                      layoutVersion: try row.optionalText("layout_version", as: Version.init))
    }

    private func liveActivity(_ device: Device, name: ActivityName) throws -> Activity? {
        try db.query("SELECT * FROM activities WHERE device_id = ? AND name = ? AND phase IN ('starting', 'live')", device.id, name)
            .first.map(Activity.init)
    }

    private func activity(_ id: UUID) throws -> Activity {
        try Activity(db.query("SELECT * FROM activities WHERE id = ?", id)[0])
    }

    private func count(_ rows: [Row]) throws -> Int {
        Int(try rows[0].integer("n"))
    }

    private func decode(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private static func text(_ value: JSONValue) -> String {
        String(decoding: value.json, as: UTF8.self)
    }

    private static func token(_ prefix: String) -> String {
        var generator = SystemRandomNumberGenerator()
        return prefix + hex((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func hash(_ token: String) -> String {
        hex(Array(SHA256.hash(data: Data(token.utf8))))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String($0 >> 4, radix: 16) + String($0 & 0xF, radix: 16) }.joined()
    }
}
