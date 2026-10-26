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
extension Name: SQLBindable {}
extension Activity.Phase: SQLBindable {}
extension NotificationSettings.Authorization: SQLBindable {}
extension NotificationSettings.AlertStyle: SQLBindable {}

extension ActionRecord {
    init(_ row: Row) throws {
        seq = try row.integer("seq")
        activity = try row.text("name", as: Name.init(rawValue:))
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
    static let activityLifetime = 8 * 3600
    private static let latestActivityEnd = activityLifetime - 60
    static let notificationLifetime = 86400
    static let maximumNotificationsPerHour = 60
    static let mediaRetention = 86400
    static let maximumMediaBytesPerDevice = 32 << 20

    private let db: Database

    init(path: String) throws {
        let db = try Database(path: path)
        try Schema.migrate(db)
        self.db = db
    }

    static func backup(_ database: String, to path: String) throws {
        guard FileManager.default.fileExists(atPath: database) else { throw ConfigurationError("There is no database at \(database).") }
        try Database(path: database).run("VACUUM INTO ?", path)
    }

    func registerDevice(environment: PushEnvironment, appVersion: String, admission: Admission, credentials: Credentials, maximumDevices: Int, now: Int) throws {
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
            try db.run("""
                INSERT INTO devices (id, secret_hash, agent_hash, environment, app_version, attestation_key, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, id, Self.hash(credentials.deviceSecret), Self.hash(credentials.agentToken), environment, appVersion, attestationKey, now)
            try record("device.registered", device: id, activity: nil, [
                "environment": .string(environment.rawValue), "appVersion": .string(appVersion),
                "admission": .string(attestationKey == nil ? "invite" : "attestation"),
            ])
        }
    }

    static func newCredentials() -> Credentials {
        Credentials(deviceSecret: token("lykta_device_"), agentToken: token("lykta_agent_"))
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
            if let notifications = report.notifications {
                try db.run("UPDATE devices SET notification_authorization = ?, alert_style = ? WHERE id = ?",
                           notifications.authorization, notifications.alertStyle, device.id)
                switch notifications.registration {
                case .pending:
                    break
                case let .registered(token):
                    try db.run("UPDATE devices SET notification_token = ?, notification_error = NULL WHERE id = ?", token, device.id)
                case let .failed(error):
                    try db.run("UPDATE devices SET notification_error = ? WHERE id = ?", error, device.id)
                }
            } else {
                try db.run("""
                    UPDATE devices SET notification_authorization = NULL, alert_style = NULL, notification_token = NULL, notification_error = NULL WHERE id = ?
                    """, device.id)
            }
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
            let token = Self.describe(report.pushToStartToken, previous: device.pushToken)
            try record("device.sync", device: device.id, activity: nil, [
                "appVersion": .string(report.appVersion),
                "layoutVersion": report.layoutVersion.map { .string($0.description) } ?? .null,
                "install": .string(report.bundleInstance.uuidString),
                "newInstall": .bool(isNewInstall),
                "pushToStartToken": .string(token),
                "notifications": report.notifications.map { settings in
                    var detail: [String: JSONValue] = [
                        "authorization": .string(settings.authorization.rawValue), "alertStyle": .string(settings.alertStyle.rawValue),
                        "token": .string(Self.describe(settings.token, previous: device.notifications?.token)),
                    ]
                    if case let .failed(error) = settings.registration { detail["registrationError"] = .string(error) }
                    return .object(detail)
                } ?? .null,
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

    func put(_ device: Device, name: Name, request: ActivityRequest, maximumLiveActivities: Int, now: Int) throws -> (activity: Activity, payloadBytes: Int) {
        try db.transaction {
            let current = try liveActivity(device, name: name)
            if let expected = request.ifRevision, current?.revision != expected {
                throw APIError(.conflict, "The activity is no longer at revision \(expected). Read it again, then send your change.")
            }
            guard let title = request.title ?? current?.title, let layout = try request.layout ?? current.map({ try decode($0.layout) }) else {
                throw APIError(.invalidRequest, "Starting an activity needs a title and a layout.")
            }
            var data = try request.data ?? current.map { try decode($0.data) } ?? .object([:])
            for (path, offset) in request.now ?? [:] {
                do { data = try data.setting(path, to: .number(Double(now) + offset)) }
                catch { throw APIError(.invalidRequest, "now: \(error)") }
            }
            let state = try Self.content(title: title, layout: layout, data: data)
            let expandedLayout: JSONValue
            do { expandedLayout = try layout.expandingParts() }
            catch let error as LayoutError { throw APIError(.invalidLayout, error.description) }
            try Self.admit(state, on: device)
            let content = try Self.encoded(state)
            let alert = try request.alert.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            let staleAfter = request.staleAfter ?? current?.staleAfter
            let relevance = request.relevance ?? current?.relevance
            let endsAt = request.endAfter.map { now + $0 } ?? current?.endsAt
            let id: UUID
            if let current {
                id = current.id
                let changed = try title != current.title || expandedLayout != decode(current.layout) || data != decode(current.data) || alert != nil
                    || request.staleAfter != nil || relevance != current.relevance || endsAt != current.endsAt
                if changed {
                    try db.run("""
                        UPDATE activities SET title = ?, layout = ?, data = ?, content = ?, stale_after = ?, ends_at = ?, relevance = ?,
                          alert = COALESCE(?, alert), revision = revision + 1 WHERE id = ?
                        """, title, Self.text(expandedLayout), Self.text(data), content, staleAfter, endsAt, relevance, alert, id)
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
                    """, id, device.id, name, title, Self.text(expandedLayout), Self.text(data), content, staleAfter, endsAt, relevance, alert, now)
            }
            let activity = try self.activity(id)
            let size = try Self.measure(activity, on: device, now: now)
            try record("activity.put", device: device.id, activity: id, [
                "name": .string(name.rawValue), "created": .bool(current == nil), "revision": .number(Double(activity.revision)),
                "fingerprint": .string(try activity.fingerprint()), "payloadBytes": .number(Double(size)), "alert": .bool(request.alert != nil),
                "endsAt": activity.endsAt.map { .number(Double($0)) } ?? .null,
            ])
            return (activity, size)
        }
    }

    func attempted(_ activity: Activity, now: Int) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM activities WHERE id = ? AND in_flight = 0 AND (sent_revision >= ? OR phase = 'ended' OR retry_at > ?)
            """, activity.id, activity.revision, now).isEmpty
    }

    func end(_ device: Device, name: Name, dismissAfter: Int?, now: Int) throws -> ActivityStatus {
        try db.transaction {
            guard let current = try liveActivity(device, name: name) else {
                throw APIError(.notFound, "No live activity is named \(name).")
            }
            return try end(current, dismissAt: dismissAfter.map { now + $0 }, now: now,
                           ["dismissAfter": dismissAfter.map { .number(Double($0)) } ?? .null]).status
        }
    }

    func detail(_ device: Device, name: Name) throws -> ActivityDetail {
        guard let row = try db.query("SELECT * FROM activities WHERE device_id = ? AND name = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
                                     device.id, name).first else {
            throw APIError(.notFound, "No activity is named \(name).")
        }
        return try detail(device, of: try Activity(row))
    }

    func detail(_ device: Device, id: UUID) throws -> ActivityDetail {
        try detail(device, of: try activity(id))
    }

    private func detail(_ device: Device, of activity: Activity) throws -> ActivityDetail {
        ActivityDetail(status: try status(of: activity, observations: observations(device, of: [activity])), data: try decode(activity.data))
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

    func putNotification(_ device: Device, name: Name, request: NotificationRequest, now: Int) throws -> Bool {
        try db.transaction {
            try expireNotifications(now: now)
            try db.run("DELETE FROM notifications WHERE device_id = ? AND name = ? AND expires_at <= ? AND in_flight = 0", device.id, name, now)
            let canonical = request.canonical
            if let row = try db.query("SELECT * FROM notifications WHERE device_id = ? AND name = ?", device.id, name).first {
                guard try row.string("request") == canonical else {
                    throw APIError(.conflict, "Another notification already uses the name \(name) until \(Self.time(try row.integer("expires_at"))). "
                                   + "Give each event its own name, and repeat a request only to retry it.")
                }
                return false
            }
            for reference in request.references {
                guard let medium = try db.query("SELECT kind FROM media WHERE id = ? AND device_id = ?", reference.id.rawValue, device.id).first else {
                    throw APIError(.invalidRequest, "\(reference.path) is \(reference.id), which this phone has not uploaded or the gateway removed "
                                   + "a day after its last use. Upload the file with POST /v1/media and use the id it returns.")
                }
                guard try medium.string("kind") == reference.kind.rawValue else {
                    throw APIError(.invalidRequest, "\(reference.path) must be \(reference.kind == .image ? "an image" : "a sound"); "
                                   + "\(reference.id) is \(reference.kind == .image ? "a sound" : "an image").")
                }
            }
            try Self.admitNotifications(on: device)
            let recent = try db.query("SELECT count(*) AS n, min(created_at) AS oldest FROM notifications WHERE device_id = ? AND created_at > ?",
                                      device.id, now - 3600)
            if try count(recent) >= Self.maximumNotificationsPerHour {
                let wait = max(1, Int(try recent[0].integer("oldest")) + 3600 - now)
                var error = APIError(.tooManyNotifications, "This phone got \(Self.maximumNotificationsPerHour) notifications in the last hour. "
                                     + "Send the next one in \(wait) seconds, or combine updates into one notification or a Live Activity.")
                error.retryAfter = wait
                throw error
            }
            let id = UUID()
            let size = try request.payload(id: id, token: Self.token("lykta_fetch_")).count
            guard size <= Self.maximumPayloadBytes else {
                throw APIError(.payloadTooLarge, "The push payload would be \(size) bytes; APNs allows \(Self.maximumPayloadBytes). Shorten the body.")
            }
            try db.run("""
                INSERT INTO notifications (id, device_id, name, request, state, created_at, expires_at) VALUES (?, ?, ?, ?, 'queued', ?, ?)
                """, id, device.id, name, canonical, now, now + Self.notificationLifetime)
            for reference in request.references {
                try db.run("UPDATE media SET used_at = ? WHERE id = ?", now, reference.id.rawValue)
            }
            let sound = switch request.sound {
            case nil: "none"
            case .default?: "default"
            case let .medium(id)?: id.rawValue
            }
            try record("notification.put", device: device.id, activity: nil, [
                "notification": .string(id.uuidString), "name": .string(name.rawValue), "sender": .string(request.sender.id.rawValue),
                "avatar": request.sender.avatar.map { .string($0.rawValue) } ?? .null, "sound": .string(sound),
                "image": request.image.map { .string($0.rawValue) } ?? .null, "fingerprint": .string(fingerprint(canonical.utf8)),
                "payloadBytes": .number(Double(size)),
            ])
            return true
        }
    }

    func notificationAttempted(_ device: Device, name: Name, now: Int) throws -> Bool {
        try !db.query("""
            SELECT 1 FROM notifications WHERE device_id = ? AND name = ? AND in_flight = 0 AND (state NOT IN ('queued', 'sending') OR retry_at > ?)
            """, device.id, name, now).isEmpty
    }

    func notification(_ device: Device, name: Name, now: Int) throws -> NotificationStatus {
        guard let row = try db.query("SELECT * FROM notifications WHERE device_id = ? AND name = ? AND expires_at > ?", device.id, name, now).first else {
            throw APIError(.notFound, "No notification is named \(name); the gateway keeps notifications for a day.")
        }
        return try notificationStatus(row, of: device)
    }

    func putMedium(_ device: Device, bytes: [UInt8], now: Int) throws -> (status: MediumStatus, created: Bool) {
        let medium = try Medium.validate(bytes)
        let hash = Self.hex(Array(SHA256.hash(data: Data(bytes))))
        return try db.transaction {
            try db.run("DELETE FROM media WHERE device_id = ? AND used_at <= ?", device.id, now - Self.mediaRetention)
            if let row = try db.query("SELECT id FROM media WHERE device_id = ? AND hash = ?", device.id, hash).first {
                let id = try row.text("id", as: MediaID.init(rawValue:))
                try db.run("UPDATE media SET used_at = ? WHERE id = ?", now, id.rawValue)
                return (MediumStatus(id: id, type: medium.kind, durationSeconds: medium.seconds), false)
            }
            let stored = try db.query("SELECT coalesce(sum(length(bytes)), 0) AS total FROM media WHERE device_id = ?", device.id)[0].integer("total")
            guard Int(stored) + bytes.count <= Self.maximumMediaBytesPerDevice else {
                throw APIError(.payloadTooLarge, "This phone's media would take \(Self.megabytes(Int(stored) + bytes.count)) MiB; the gateway keeps at most "
                               + "\(Self.maximumMediaBytesPerDevice >> 20) MiB per phone, each file until a day after its last upload or use. "
                               + "Reuse the ids of files you uploaded, or send smaller files.")
            }
            let id = MediaID.random()
            try db.run("""
                INSERT INTO media (id, device_id, hash, kind, content_type, bytes, used_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, id.rawValue, device.id, hash, medium.kind.rawValue, medium.contentType, bytes, now)
            try record("media.put", device: device.id, activity: nil, [
                "media": .string(id.rawValue), "type": .string(medium.kind.rawValue), "bytes": .number(Double(bytes.count)),
                "durationSeconds": medium.seconds.map(JSONValue.number) ?? .null, "fingerprint": .string(String(hash.prefix(16))),
            ])
            return (MediumStatus(id: id, type: medium.kind, durationSeconds: medium.seconds), true)
        }
    }

    func notificationMedium(_ id: UUID, token: String, medium mediaID: MediaID, now: Int) throws -> (bytes: [UInt8], contentType: String) {
        try db.transaction {
            guard let row = try db.query("SELECT device_id, request FROM notifications WHERE id = ? AND token_hash = ? AND expires_at > ?",
                                         id, Self.hash(token), now).first else {
                throw APIError(.unauthorized, "The notification is unknown, expired or belongs to another push.")
            }
            let request = try JSONDecoder().decode(NotificationRequest.self, from: Data(try row.string("request").utf8))
            let device = try row.text("device_id", as: UUID.init(uuidString:))
            guard request.references.contains(where: { $0.id == mediaID }),
                  let medium = try db.query("SELECT bytes, content_type FROM media WHERE id = ? AND device_id = ?", mediaID.rawValue, device).first else {
                throw APIError(.notFound, "The notification has no medium \(mediaID).")
            }
            let bytes = try medium.blob("bytes")
            try record("notification.media", source: "app", device: device, activity: nil, [
                "notification": .string(id.uuidString), "media": .string(mediaID.rawValue), "bytes": .number(Double(bytes.count)),
            ])
            return (bytes, try medium.string("content_type"))
        }
    }

    func reportNotification(_ id: UUID, token: String, _ report: NotificationReport, now: Int) throws {
        try db.transaction {
            guard let row = try db.query("SELECT device_id, name, phone FROM notifications WHERE id = ? AND token_hash = ? AND expires_at > ?",
                                         id, Self.hash(token), now).first else {
                throw APIError(.unauthorized, "The notification is unknown, expired or belongs to another push.")
            }
            guard try row.optionalString("phone") == nil else { return }
            let json = try JSONEncoder().encode(report)
            try db.run("UPDATE notifications SET phone = ?, state = 'received', error = NULL WHERE id = ?", String(decoding: json, as: UTF8.self), id)
            try record("notification.received", source: "app", device: try row.text("device_id", as: UUID.init(uuidString:)), activity: nil,
                       try JSONDecoder().decode([String: JSONValue].self, from: json).merging([
                           "notification": .string(id.uuidString), "name": .string(try row.string("name")),
                       ]) { $1 })
        }
    }

    private func expireNotifications(now: Int) throws {
        for row in try db.query("SELECT id, device_id, name FROM notifications WHERE state = 'queued' AND expires_at <= ?", now) {
            let id = try row.text("id", as: UUID.init(uuidString:))
            try db.run("UPDATE notifications SET state = 'failed', error = 'The notification expired before Apple accepted it.' WHERE id = ?", id)
            try record("notification.expired", device: try row.text("device_id", as: UUID.init(uuidString:)), activity: nil,
                       ["notification": .string(id.uuidString), "name": .string(try row.string("name"))])
        }
    }

    private func notificationStatus(_ row: Row, of device: Device) throws -> NotificationStatus {
        let state: NotificationStatus.State = switch try row.string("state") {
        case "queued", "sending": .queued
        case "sent": .sent
        case "received": .received
        case "failed": .failed
        case "unknown": .unknown
        case let other: throw SQLiteError(code: 0, message: "notification state \(other) is not one the gateway writes")
        }
        return NotificationStatus(name: try row.text("name", as: Name.init(rawValue:)), state: state, error: try row.optionalString("error"),
                                  phone: try row.optionalString("phone").map { try JSONDecoder().decode(NotificationReport.self, from: Data($0.utf8)) },
                                  banners: NotificationStatus.Banners(device.notifications?.alertStyle),
                                  createdAt: Date(timeIntervalSince1970: Double(try row.integer("created_at"))),
                                  expires: Date(timeIntervalSince1970: Double(try row.integer("expires_at"))))
    }

    private static func admitNotifications(on device: Device) throws {
        guard let settings = device.notifications else {
            throw APIError(.appUpdateRequired, "This phone runs Lykta \(device.appVersion), and notifications need Lykta 0.6.0 or later. "
                           + "Ask the user to update Lykta and open it once, or use a Live Activity.")
        }
        switch settings.authorization {
        case .denied:
            throw APIError(.notificationsNotAllowed, "The user turned off notifications for Lykta. Ask them to allow them in Settings > Notifications > Lykta, "
                           + "or use a Live Activity.")
        case .notDetermined:
            throw APIError(.notificationsNotSetUp, "The user has not allowed notifications yet. Ask them to open Lykta and allow notifications.")
        case .authorized, .provisional, .ephemeral:
            switch settings.registration {
            case .registered:
                break
            case .pending:
                throw APIError(.notificationsNotSetUp, "The phone has not shared its notification token yet. Ask the user to open Lykta.")
            case let .failed(error):
                throw APIError(.notificationsNotSetUp, "iOS refused Lykta a notification token on this phone (“\(error)”). "
                               + "Ask the user to update Lykta, or use a Live Activity.")
            }
        }
    }

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
                _ = try Self.measure(self.activity(activity.id), on: device, now: now)
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

    func recover() throws {
        try db.execute("""
            UPDATE activities SET phase = 'live', delivery = 'unknown', error = 'The gateway restarted while starting this activity.'
              WHERE in_flight = 1 AND phase = 'starting' AND channel IS NOT NULL;
            UPDATE activities SET in_flight = 0;
            """)
        try db.transaction {
            for row in try db.query("SELECT id, device_id, name FROM notifications WHERE state = 'sending'") {
                let id = try row.text("id", as: UUID.init(uuidString:))
                try db.run("UPDATE notifications SET state = 'unknown', error = 'The gateway restarted while sending this notification.' WHERE id = ?", id)
                try record("notification.unknown", device: try row.text("device_id", as: UUID.init(uuidString:)), activity: nil,
                           ["notification": .string(id.uuidString), "name": .string(try row.string("name"))])
            }
            try db.run("UPDATE notifications SET in_flight = 0")
        }
    }

    func housekeep(now: Int) throws {
        try db.transaction {
            for row in try db.query("SELECT id, device_id FROM activities WHERE phase != 'ended' AND in_flight = 0 AND created_at <= ?", now - Self.activityLifetime) {
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
        try db.transaction {
            try expireNotifications(now: now)
            try db.run("DELETE FROM notifications WHERE expires_at <= ? AND in_flight = 0", now)
        }
        try db.run("DELETE FROM media WHERE used_at <= ?", now - Self.mediaRetention)
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
            for row in try db.query("""
                SELECT * FROM activities WHERE phase IN ('starting', 'live') AND ends_at IS NOT NULL AND min(ends_at, created_at + ?) <= ?
                """, Self.latestActivityEnd, now) {
                _ = try end(Activity(row), dismissAt: now, now: now, ["dismissAfter": .number(0), "scheduled": .bool(true)])
            }
            try expireNotifications(now: now)
            var free = limit - (try count(db.query("SELECT count(*) AS n FROM activities WHERE in_flight = 1")))
                - (try count(db.query("SELECT count(*) AS n FROM notifications WHERE in_flight = 1")))
            guard free > 0 else { return [] }
            var jobs = try db.query("""
                SELECT n.id, n.device_id, n.name, n.request, n.expires_at, d.environment, d.notification_token, d.moved_notification_token_hash
                  FROM notifications n JOIN devices d ON d.id = n.device_id
                  WHERE n.state = 'queued' AND n.retry_at <= ? AND d.notification_token IS NOT NULL ORDER BY n.retry_at, n.created_at LIMIT ?
                """, now, free).map { row in
                let id = try row.text("id", as: UUID.init(uuidString:))
                let fetchToken = Self.token("lykta_fetch_")
                let device = try row.text("environment", as: PushEnvironment.init(rawValue:))
                let token = try row.text("notification_token", as: PushToken.init(hex:))
                let moved = try row.optionalString("moved_notification_token_hash") == Self.hash(token.description)
                try db.run("UPDATE notifications SET state = 'sending', in_flight = 1, token_hash = ? WHERE id = ?", Self.hash(fetchToken), id)
                return Job.notification(NotificationJob(
                    id: id, deviceID: try row.text("device_id", as: UUID.init(uuidString:)), name: try row.text("name", as: Name.init(rawValue:)),
                    request: try JSONDecoder().decode(NotificationRequest.self, from: Data(try row.string("request").utf8)),
                    environment: moved ? device.other : device,
                    token: token, tokenMoved: moved, fetchToken: fetchToken,
                    expiresAt: Int(try row.integer("expires_at"))))
            }
            free -= jobs.count
            guard free > 0 else { return jobs }
            let rows = try db.query("""
                SELECT a.*, d.environment, d.push_token, d.moved_push_token_hash, d.layout_version FROM activities a JOIN devices d ON d.id = a.device_id
                WHERE a.in_flight = 0 AND a.retry_at <= ?1 AND (
                  (a.phase = 'starting' AND d.push_token IS NOT NULL)
                  OR (a.phase = 'live' AND a.revision > a.sent_revision AND a.last_sent_at < ?1)
                  OR (a.phase = 'ending' AND a.last_sent_at < ?1)
                  OR (a.phase = 'ended' AND a.channel IS NOT NULL AND a.ended_at <= ?1 - 300))
                ORDER BY a.retry_at, a.last_sent_at LIMIT ?2
                """, now, free)
            jobs += try rows.map { row in
                let activity = try Activity(row)
                try db.run("UPDATE activities SET in_flight = 1, last_sent_at = ?, alert = NULL WHERE id = ?", now, activity.id)
                let kind: ActivityJob.Kind = switch activity.phase {
                case .starting: .start
                case .live: .update
                case .ending: .end
                case .ended: .deleteChannel
                }
                let device = try row.text("environment", as: PushEnvironment.init(rawValue:))
                let token = try row.optionalText("push_token", as: PushToken.init(hex:))
                let movedHash = try row.optionalString("moved_push_token_hash")
                let moved = token.map { Self.hash($0.description) == movedHash } ?? false
                return Job.activity(ActivityJob(kind: kind, activity: activity,
                                                environment: kind == .start ? (moved ? device.other : device) : activity.channelEnvironment ?? device,
                                                pushToken: token, tokenMoved: moved,
                                                layoutVersion: try row.optionalText("layout_version", as: Version.init)))
            }
            return jobs
        }
    }

    func setChannel(_ channel: String, environment: PushEnvironment, for activityID: UUID) throws -> Bool {
        try db.run("UPDATE activities SET channel = ?, channel_environment = ? WHERE id = ?", channel, environment, activityID)
        return try !db.query("SELECT 1 FROM activities WHERE id = ?", activityID).isEmpty
    }

    func channels() throws -> Set<String> {
        Set(try db.query("SELECT channel FROM activities WHERE channel IS NOT NULL").map { try $0.string("channel") })
    }

    func finish(_ job: Job, _ attempt: Attempt, now: Int) throws {
        switch job {
        case let .activity(job): try finish(job, attempt, now: now)
        case let .notification(job): try finish(job, attempt, now: now)
        }
    }

    private func finish(_ job: NotificationJob, _ attempt: Attempt, now: Int) throws {
        let (result, error): (String, String?) = switch attempt.outcome {
        case .accepted: ("accepted", nil)
        case let .retry(error, throttled): (throttled ? "throttled" : "retry", error)
        case let .failed(error, _): ("failed", error)
        case let .unknown(error): ("unknown", error)
        case let .wrongEnvironment(error): ("wrongEnvironment", error)
        case .channelGone: preconditionFailure("notification pushes use no channel")
        }
        try db.transaction {
            guard let row = try db.query("SELECT failures FROM notifications WHERE id = ?", job.id).first else { return }
            try record("push.notification", device: job.deviceID, activity: nil,
                       attempt.detail.merging(["outcome": .string(result), "error": error.map(JSONValue.string) ?? .null]) { $1 })
            try db.run("UPDATE notifications SET in_flight = 0 WHERE id = ?", job.id)
            switch attempt.outcome {
            case .accepted:
                try db.run("UPDATE notifications SET state = 'sent', error = NULL WHERE id = ? AND state = 'sending'", job.id)
            case let .unknown(error):
                try db.run("UPDATE notifications SET state = 'unknown', error = ? WHERE id = ? AND state = 'sending'", error, job.id)
            case let .retry(error, _):
                try db.run("""
                    UPDATE notifications SET state = 'queued', token_hash = NULL, retry_at = ?, failures = failures + 1, error = ?
                      WHERE id = ? AND state = 'sending'
                    """, now + min(1 << min(Int(try row.integer("failures")) + 1, 9), 300), error, job.id)
            case let .failed(error, clearsPushToken):
                try db.run("UPDATE notifications SET state = 'failed', error = ? WHERE id = ? AND state = 'sending'", error, job.id)
                if clearsPushToken, try !db.query("SELECT 1 FROM devices WHERE id = ? AND notification_token = ?", job.deviceID, job.token).isEmpty {
                    try db.run("UPDATE devices SET notification_token = NULL WHERE id = ?", job.deviceID)
                    for waiting in try db.query("SELECT id, name FROM notifications WHERE device_id = ? AND state = 'queued'", job.deviceID) {
                        let id = try waiting.text("id", as: UUID.init(uuidString:))
                        try db.run("UPDATE notifications SET state = 'failed', error = ? WHERE id = ?", error, id)
                        try record("notification.failed", device: job.deviceID, activity: nil,
                                   ["notification": .string(id.uuidString), "name": .string(try waiting.string("name")), "error": .string(error)])
                    }
                }
            case .wrongEnvironment:
                try db.run("UPDATE devices SET moved_notification_token_hash = ? WHERE id = ? AND notification_token = ?",
                           Self.hash(job.token.description), job.deviceID, job.token)
                try db.run("UPDATE notifications SET state = 'queued', token_hash = NULL WHERE id = ? AND state = 'sending'", job.id)
            case .channelGone:
                preconditionFailure("notification pushes use no channel")
            }
        }
    }

    private func finish(_ job: ActivityJob, _ attempt: Attempt, now: Int) throws {
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
            case let .wrongEnvironment(error): ("wrongEnvironment", error)
            }
            try record("push.\(job.kind.rawValue)", device: job.activity.deviceID, activity: id,
                       attempt.detail.merging(["outcome": .string(result), "error": error.map(JSONValue.string) ?? .null]) { $1 })
            let alert = try job.activity.alert.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            switch (job.kind, outcome) {
            case let (_, .retry(error, throttled)):
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
                    try db.run("UPDATE devices SET push_token = NULL WHERE id = ? AND push_token = ?", job.activity.deviceID, job.pushToken)
                }
            case (_, .channelGone):
                try db.run("""
                    UPDATE activities SET phase = 'ended', ended_at = COALESCE(ended_at, ?), channel = NULL,
                      error = 'The broadcast channel no longer exists.' WHERE id = ?
                    """, now, id)
            case (.start, .wrongEnvironment):
                try db.run("UPDATE devices SET moved_push_token_hash = ? WHERE id = ? AND push_token = ?",
                           job.pushToken.map { Self.hash($0.description) }, job.activity.deviceID, job.pushToken)
                try db.run("UPDATE activities SET alert = COALESCE(alert, ?) WHERE id = ?", alert, id)
            case (_, .unknown):
                preconditionFailure("unknown outcomes of non-start jobs are retried")
            case (_, .wrongEnvironment):
                preconditionFailure("only pushes to a token change its environment")
            }
            try db.run("UPDATE activities SET in_flight = 0 WHERE id = ?", id)
        }
    }

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

    private static func measure(_ activity: Activity, on device: Device, now: Int) throws -> Int {
        let (size, stored) = try activity.admissionBytes(now: now, layoutVersion: device.layoutVersion)
        let limit = maximumPayloadBytes
        let exceeded = if size > limit {
            "The push payload would be \(size) bytes; APNs allows \(limit)."
        } else if stored > limit {
            "The activity's name and content would be \(stored) bytes; iOS allows \(limit) for a Live Activity."
        } else {
            String?.none
        }
        guard let exceeded else { return size }
        let layout = try JSONDecoder().decode(JSONValue.self, from: Data(activity.layout.utf8))
        let data = try JSONDecoder().decode(JSONValue.self, from: Data(activity.data.utf8))
        throw APIError(.payloadTooLarge, "\(exceeded) " + (try LayoutCost.describe(layout.filled(with: data), for: device.layoutVersion)))
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

    private func record(_ name: String, source: String = "gateway", device: UUID, activity: UUID?, _ detail: [String: JSONValue]) throws {
        let now = Self.milliseconds(.now)
        let json = String(decoding: JSONValue.object(detail).json, as: UTF8.self)
        try db.run("""
            INSERT INTO events (id, device_id, activity_id, source, name, at, received_at, bytes, detail)
              VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, UUID(), device, activity, source, name, now, now, json.utf8.count, json)
    }

    private static func describe(_ token: PushToken?, previous: PushToken?) -> String {
        switch token {
        case nil: "none"
        case previous: "unchanged"
        case let .some(token): "new \(fingerprint(token.description.utf8))"
        }
    }

    private static func time(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: Double(seconds)).ISO8601Format()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func device(column: String, hash: String) throws -> Device? {
        guard let row = try db.query("""
            SELECT id, environment, push_token, app_version, layout_version, notification_authorization, alert_style, notification_token,
                   notification_error
              FROM devices WHERE \(column) = ?
            """, hash).first else {
            return nil
        }
        let notifications = try row.optionalText("notification_authorization", as: NotificationSettings.Authorization.init(rawValue:)).map {
            let registration: NotificationSettings.Registration = if let token = try row.optionalText("notification_token", as: PushToken.init(hex:)) {
                .registered(token)
            } else if let error = try row.optionalString("notification_error") {
                .failed(error)
            } else {
                .pending
            }
            return NotificationSettings(authorization: $0, alertStyle: try row.text("alert_style", as: NotificationSettings.AlertStyle.init(rawValue:)),
                                        registration: registration)
        }
        return Device(id: try row.text("id", as: UUID.init(uuidString:)),
                      environment: try row.text("environment", as: PushEnvironment.init(rawValue:)),
                      pushToken: try row.optionalText("push_token", as: PushToken.init(hex:)),
                      appVersion: try row.string("app_version"),
                      layoutVersion: try row.optionalText("layout_version", as: Version.init),
                      notifications: notifications)
    }

    private func liveActivity(_ device: Device, name: Name) throws -> Activity? {
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

    private static func megabytes(_ bytes: Int) -> String {
        String(format: "%.1f", Double(bytes) / Double(1 << 20))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String($0 >> 4, radix: 16) + String($0 & 0xF, radix: 16) }.joined()
    }
}
