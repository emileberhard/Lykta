import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LyktaCore

struct ActivityRequest: Sendable {
    let title: String?
    let layout: JSONValue?
    let data: JSONValue?
    let alert: Alert?
    let staleAfter: Int?
    let relevance: Double?
}

struct Job: Sendable {
    enum Kind: String, Sendable { case start, update, end, deleteChannel }

    let kind: Kind
    let activity: Activity
    let environment: PushEnvironment
    let pushToken: PushToken?
}

enum Outcome: Sendable {
    case accepted
    case retry(String, throttled: Bool)
    case failed(String, clearsPushToken: Bool)
    case unknown(String)
    case channelGone
}

struct Attempt: Sendable {
    let outcome: Outcome
    let detail: [String: JSONValue]
}

struct StoredEvent: Encodable, Sendable {
    let seq: Int64
    let device: UUID
    let activity: UUID?
    let source: String
    let name: String
    let at: Date
    let receivedAt: Date
    let detail: JSONValue

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

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(seq, forKey: .seq)
        try fields.encode(device, forKey: .device)
        try fields.encode(activity, forKey: .activity)
        try fields.encode(source, forKey: .source)
        try fields.encode(name, forKey: .name)
        try fields.encode(at.formatted(Self.time), forKey: .at)
        try fields.encode(receivedAt.formatted(Self.time), forKey: .receivedAt)
        try fields.encode(detail, forKey: .detail)
    }

    private static let time = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private enum CodingKeys: String, CodingKey {
        case seq, device, activity, source, name, at, receivedAt, detail
    }
}

extension PushToken: SQLBindable {
    var sqlValue: SQLValue { .text(description) }
}

extension PushEnvironment: SQLBindable {}
extension ObservedState: SQLBindable {}
extension DeliveryState: SQLBindable {}
extension ActivityName: SQLBindable {}
extension Activity.Phase: SQLBindable {}

actor Store {
    static let maximumAttempts = 5
    static let maximumPayloadBytes = 4096
    static let eventRetention = 14 * 86400
    static let maximumEventBytesPerDevice = 8 << 20

    private let db: Database
    private let maximumDevices: Int
    private let maximumLiveActivities: Int

    init(path: String, maximumDevices: Int, maximumLiveActivities: Int) throws {
        db = try Database(path: path)
        self.maximumDevices = maximumDevices
        self.maximumLiveActivities = maximumLiveActivities
        try db.execute(Self.schema)
    }

    // MARK: Devices

    func registerDevice(environment: PushEnvironment, appVersion: String, now: Int) throws -> Credentials {
        try db.transaction {
            guard try count(db.query("SELECT count(*) AS n FROM devices")) < maximumDevices else {
                throw APIError(.registrationClosed, "This gateway accepts no more devices.")
            }
            let id = UUID()
            let secret = Self.token("lykta_device_")
            let agentToken = Self.token("lykta_agent_")
            try db.run("INSERT INTO devices (id, secret_hash, agent_hash, environment, app_version, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                       id, Self.hash(secret), Self.hash(agentToken), environment, appVersion, now)
            try record("device.registered", device: id, activity: nil,
                       ["environment": .string(environment.rawValue), "appVersion": .string(appVersion)])
            return Credentials(deviceSecret: secret, agentToken: agentToken)
        }
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
            try db.run("UPDATE devices SET push_token = COALESCE(?, push_token), app_version = ?, bundle_instance = ? WHERE id = ?",
                       report.pushToStartToken, report.appVersion, report.bundleInstance, device.id)
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
            guard let title = request.title ?? current?.title, let layout = try request.layout ?? current.map({ try decode($0.layout) }) else {
                throw APIError(.invalidRequest, "Starting an activity needs a title and a layout.")
            }
            let data = try request.data ?? current.map { try decode($0.data) } ?? .object([:])
            let content: String
            do {
                let state = try LyktaActivity.ContentState(title: title, layout: layout.filled(with: data).json)
                content = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
            } catch let error as LayoutError {
                throw APIError(.invalidLayout, error.description)
            }
            let alert = try request.alert.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            let staleAfter = request.staleAfter ?? current?.staleAfter
            let relevance = request.relevance ?? current?.relevance
            let id: UUID
            if let current {
                id = current.id
                if content != current.content || alert != nil || request.staleAfter != nil || relevance != current.relevance {
                    try db.run("""
                        UPDATE activities SET title = ?, layout = ?, data = ?, content = ?, stale_after = ?, relevance = ?,
                          alert = COALESCE(?, alert), revision = revision + 1 WHERE id = ?
                        """, title, Self.text(layout), Self.text(data), content, staleAfter, relevance, alert, id)
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
                    INSERT INTO activities (id, device_id, name, phase, title, layout, data, content, stale_after, relevance, alert,
                      revision, delivery, created_at) VALUES (?, ?, ?, 'starting', ?, ?, ?, ?, ?, ?, ?, 1, 'pending', ?)
                    """, id, device.id, name, title, Self.text(layout), Self.text(data), content, staleAfter, relevance, alert, now)
            }
            let activity = try self.activity(id)
            let size = try activity.payload(activity.phase == .starting ? .start : .update, now: now,
                                            channel: String(repeating: "x", count: 64), alert: activity.alert).count
            guard size <= Self.maximumPayloadBytes else {
                throw APIError(.payloadTooLarge,
                               "The push payload would be \(size) bytes; APNs allows \(Self.maximumPayloadBytes). Simplify the layout or shorten its text.")
            }
            try record("activity.put", device: device.id, activity: id, [
                "name": .string(name.rawValue), "created": .bool(current == nil), "revision": .number(Double(activity.revision)),
                "fingerprint": .string(try activity.fingerprint()), "payloadBytes": .number(Double(size)), "alert": .bool(request.alert != nil),
            ])
            return activity.status
        }
    }

    func end(_ device: Device, name: ActivityName, dismissAfter: Int?, now: Int) throws -> ActivityStatus {
        try db.transaction {
            guard let current = try liveActivity(device, name: name) else {
                throw APIError(.notFound, "No live activity is named \(name).")
            }
            try db.run("""
                UPDATE activities SET phase = CASE WHEN phase = 'starting' AND in_flight = 0 THEN 'ended' ELSE 'ending' END,
                  ended_at = CASE WHEN phase = 'starting' AND in_flight = 0 THEN ? END, dismiss_at = ?, retry_at = 0, failures = 0
                  WHERE id = ?
                """, now, dismissAfter.map { now + $0 }, current.id)
            let ended = try activity(current.id)
            try record("activity.end", device: device.id, activity: ended.id, [
                "name": .string(name.rawValue), "phase": .string(ended.phase.rawValue),
                "dismissAfter": dismissAfter.map { .number(Double($0)) } ?? .null,
            ])
            return ended.status
        }
    }

    func status(_ device: Device, name: ActivityName) throws -> ActivityStatus {
        guard let row = try db.query("SELECT * FROM activities WHERE device_id = ? AND name = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                                     device.id, name).first else {
            throw APIError(.notFound, "No activity is named \(name).")
        }
        return try Activity(row).status
    }

    func list(_ device: Device) throws -> [ActivityStatus] {
        try db.query("SELECT * FROM activities WHERE device_id = ? ORDER BY created_at DESC, rowid DESC LIMIT 100", device.id)
            .map { try Activity($0).status }
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
        }
        try db.run("DELETE FROM activities WHERE phase = 'ended' AND channel IS NULL AND ended_at <= ?", now - 7 * 86400)
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

    func setChannel(_ channel: String, for activityID: UUID) throws {
        try db.run("UPDATE activities SET channel = ? WHERE id = ?", channel, activityID)
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
        guard let row = try db.query("SELECT id, environment, push_token FROM devices WHERE \(column) = ?", hash).first else { return nil }
        return Device(id: try row.text("id", as: UUID.init(uuidString:)),
                      environment: try row.text("environment", as: PushEnvironment.init(rawValue:)),
                      pushToken: try row.optionalText("push_token", as: PushToken.init(hex:)))
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

    private static let schema = """
        CREATE TABLE IF NOT EXISTS devices (
          id TEXT PRIMARY KEY,
          secret_hash TEXT NOT NULL UNIQUE,
          agent_hash TEXT NOT NULL UNIQUE,
          environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
          push_token TEXT,
          bundle_instance TEXT,
          app_version TEXT NOT NULL,
          created_at INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS activities (
          id TEXT PRIMARY KEY,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          phase TEXT NOT NULL CHECK (phase IN ('starting', 'live', 'ending', 'ended')),
          title TEXT NOT NULL,
          layout TEXT NOT NULL,
          data TEXT NOT NULL,
          content TEXT NOT NULL,
          stale_after INTEGER,
          relevance REAL,
          alert TEXT,
          dismiss_at INTEGER,
          revision INTEGER NOT NULL,
          sent_revision INTEGER NOT NULL DEFAULT 0,
          channel TEXT,
          in_flight INTEGER NOT NULL DEFAULT 0,
          last_sent_at INTEGER NOT NULL DEFAULT 0,
          retry_at INTEGER NOT NULL DEFAULT 0,
          failures INTEGER NOT NULL DEFAULT 0,
          delivery TEXT NOT NULL CHECK (delivery IN ('pending', 'accepted', 'throttled', 'unknown', 'failed')),
          error TEXT,
          device_state TEXT,
          created_at INTEGER NOT NULL,
          ended_at INTEGER
        ) STRICT;
        CREATE UNIQUE INDEX IF NOT EXISTS live_activity_names ON activities(device_id, name) WHERE phase IN ('starting', 'live');
        CREATE INDEX IF NOT EXISTS activity_devices ON activities(device_id);
        CREATE TABLE IF NOT EXISTS events (
          seq INTEGER PRIMARY KEY,
          id TEXT NOT NULL UNIQUE,
          device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
          activity_id TEXT,
          source TEXT NOT NULL CHECK (source IN ('app', 'gateway')),
          name TEXT NOT NULL,
          at INTEGER NOT NULL,
          received_at INTEGER NOT NULL,
          bytes INTEGER NOT NULL,
          detail TEXT NOT NULL
        ) STRICT;
        CREATE INDEX IF NOT EXISTS device_events ON events(device_id, seq);
        CREATE INDEX IF NOT EXISTS event_age ON events(received_at);
        """
}
