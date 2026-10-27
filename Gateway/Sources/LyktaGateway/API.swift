import Foundation
import LyktaCore

struct API: Sendable {
    let store: Store
    let maximumDevices: Int
    let maximumLiveActivities: Int
    let environments: Set<PushEnvironment>
    let enrolment: Enrolment
    let version: Version?
    let shutdown: Shutdown

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let failure: APIError
        do {
            return try await route(request, now: Self.now())
        } catch let error as APIError {
            failure = error
        } catch {
            log("\(request.method) /\(request.path.joined(separator: "/")) failed: \(error)")
            failure = APIError(.internal, "The gateway failed to handle the request.")
        }
        if let token = try? Self.bearer(request) {
            do {
                try await store.recordFailure(token: token, request: "\(request.method) /\(request.path.joined(separator: "/"))", failure)
            } catch {
                log("Recording a failed request failed: \(error)")
            }
        }
        return HTTPResponse(failure)
    }

    static func bodyLimit(method: String, target: String) -> Int {
        method == "POST" && HTTPRequest(method: method, target: target, headers: [:], body: []).path == ["v1", "media"] ? Medium.maximumBytes : 1 << 20
    }

    private static let skill: [String: HTTPResponse] = Dictionary(uniqueKeysWithValues: [
        "SKILL.md": PackageResources.SKILL_md,
        "references/layout.md": PackageResources.layout_md,
        "references/notifications.md": PackageResources.notifications_md,
        "examples/agent-question.json": PackageResources.agent_question_json,
        "examples/ai-usage.json": PackageResources.ai_usage_json,
        "examples/app-review.json": PackageResources.app_review_json,
        "examples/homelab.json": PackageResources.homelab_json,
        "examples/jira-release.json": PackageResources.jira_release_json,
        "examples/movie-night.json": PackageResources.movie_night_json,
        "examples/orion-return.json": PackageResources.orion_return_json,
        "examples/pr-inbox.json": PackageResources.pr_inbox_json,
        "examples/printer.json": PackageResources.printer_json,
        "examples/puppy-potty.json": PackageResources.puppy_potty_json,
        "examples/recipe-steps.json": PackageResources.recipe_steps_json,
        "examples/shopping-list.json": PackageResources.shopping_list_json,
        "examples/solar-eclipse.json": PackageResources.solar_eclipse_json,
        "examples/notifications/benchy.jpg": PackageResources.benchy_jpg,
        "examples/notifications/doorbell.json": PackageResources.doorbell_json,
        "examples/notifications/doorbell.wav": PackageResources.doorbell_wav,
        "examples/notifications/front-door-avatar.jpg": PackageResources.front_door_avatar_jpg,
        "examples/notifications/front-door.jpg": PackageResources.front_door_jpg,
        "examples/notifications/print-finished.json": PackageResources.print_finished_json,
        "examples/notifications/print-finished.wav": PackageResources.print_finished_wav,
        "examples/notifications/printer-avatar.jpg": PackageResources.printer_avatar_jpg,
        "examples/notifications/tests-passed.json": PackageResources.tests_passed_json,
        "scripts/lykta": PackageResources.lykta,
        "scripts/lykta.ps1": PackageResources.lykta_ps1,
    ].map { path, body in
        let type = switch path.split(separator: ".").last {
        case "md": "text/markdown; charset=utf-8"
        case "scripts/lykta", "ps1": "text/plain; charset=utf-8"
        case "json": "application/json"
        case "jpg": "image/jpeg"
        case "wav": "audio/wav"
        default: preconditionFailure("The skill serves no file like \(path)")
        }
        return ("skill/\(path)", HTTPResponse(status: 200, contentType: type, body: body))
    })

    private func route(_ request: HTTPRequest, now: Int) async throws -> HTTPResponse {
        let path = request.path
        if request.method == "GET", let file = Self.skill[path.joined(separator: "/")] {
            return file
        }
        switch (request.method, Self.route(path)) {
        case ("GET", "v1/version"):
            return Self.json(200, ["version": version?.description])
        case ("GET", "v1/devices/challenge"):
            return Self.json(200, Challenge(challenge: enrolment.challenge(now: now)))
        case ("POST", "v1/devices"):
            let registration: Registration = try Self.decode(request.body)
            guard environments.contains(registration.environment) else {
                throw APIError(.unsupportedEnvironment, "This gateway has no APNs key for \(registration.environment.rawValue) builds.")
            }
            let admission: Admission
            switch registration.proof {
            case let .attestation(keyID, object, challenge):
                try await enrolment.verify(keyID: keyID, object: object, challenge: challenge, now: now)
                admission = .attested(keyID: keyID)
            case let .invite(code):
                admission = .invited(code)
            }
            let credentials = Store.newCredentials()
            try await store.registerDevice(environment: registration.environment, appVersion: registration.appVersion,
                                           admission: admission, credentials: credentials, maximumDevices: maximumDevices, now: now)
            return Self.json(201, credentials)
        case ("PUT", "v1/device"):
            let device = try await phone(request)
            let report: DeviceReport = try Self.decode(request.body)
            return Self.json(200, try await store.sync(device, report: report, now: now))
        case ("DELETE", "v1/device"):
            try await store.deleteDevice(try await phone(request))
            return .noContent
        case ("POST", "v1/device/actions"):
            let device = try await phone(request)
            try await store.act(device, try Self.decode(request.body), now: now)
            return .noContent
        case ("GET", "v1/actions"):
            let device = try await agent(request)
            let wait = try Self.wait(request)
            let after = try Self.cursor(request, of: "action")
            let cursor = if let after { after } else { try await store.latestAction(device) }
            var actions: [ActionRecord] = []
            try await waiting(wait) {
                actions = try await store.actions(device, after: cursor, limit: 100)
                return !actions.isEmpty
            }
            return Self.json(200, ActionPage(actions: actions, cursor: actions.last?.seq ?? cursor))
        case ("POST", "v1/device/events"):
            let device = try await phone(request)
            try await store.ingest(device, try Self.decode(request.body))
            return .noContent
        case ("GET", "v1/events"):
            let device = try await agent(request)
            let after = try Self.cursor(request, of: "event")
            let limit = try request.query["limit"].map { text in
                guard let limit = Int(text), (1...1000).contains(limit) else { throw Self.invalid("limit must be 1 to 1000.") }
                return limit
            } ?? 200
            return Self.json(200, ["events": try await store.events(device: device.id, after: after, limit: limit)])
        case ("PUT", "v1/notifications/{name}"):
            let device = try await agent(request)
            let name = try Self.name(path[2])
            let wait = try Self.wait(request)
            let created = try await store.putNotification(device, name: name, request: try NotificationRequest.decode(try Self.decode(request.body)),
                                                          now: now)
            try await waiting(wait) { try await store.notificationAttempted(device, name: name, now: Self.now()) }
            return Self.json(created ? 201 : 200, try await store.notification(device, name: name, now: Self.now()))
        case ("GET", "v1/notifications/{name}"):
            return Self.json(200, try await store.notification(try await agent(request), name: try Self.name(path[2]), now: now))
        case ("POST", "v1/device/notifications/{id}/report"):
            try await store.reportNotification(try Self.notification(path[3]), token: try Self.bearer(request), try Self.decode(request.body), now: now)
            return .noContent
        case ("GET", "v1/device/notifications/{id}/media/{media}"):
            guard let medium = MediaID(rawValue: path[5]) else { throw APIError(.notFound, "No medium has the id \(path[5]).") }
            let (bytes, contentType) = try await store.notificationMedium(try Self.notification(path[3]), token: try Self.bearer(request),
                                                                          medium: medium, now: now)
            return HTTPResponse(status: 200, contentType: contentType, body: bytes)
        case ("POST", "v1/media"):
            let (status, created) = try await store.putMedium(try await agent(request), bytes: request.body, now: now)
            return Self.json(created ? 201 : 200, status)
        case ("GET", "v1/activities"):
            return Self.json(200, ["activities": try await store.list(try await agent(request))])
        case ("GET", "v1/activities/{name}"):
            return Self.json(200, try await store.detail(try await agent(request), name: try Self.name(path[2])))
        case ("PUT", "v1/activities/{name}"):
            let device = try await agent(request)
            let name = try Self.name(path[2])
            let wait = try Self.wait(request)
            let (activity, payloadBytes) = try await store.put(device, name: name, request: try Self.activityRequest(request.body),
                                                               maximumLiveActivities: maximumLiveActivities, now: now)
            try await waiting(wait) { try await store.attempted(activity, now: Self.now()) }
            return Self.json(200, ActivityPut(detail: try await store.detail(device, id: activity.id), payloadBytes: payloadBytes))
        case ("DELETE", "v1/activities/{name}"):
            let device = try await agent(request)
            let dismissAfter = try request.query["dismissAfter"].map { text in
                guard let seconds = Int(text), (0...4 * 3600).contains(seconds) else {
                    throw Self.invalid("dismissAfter must be 0 to 14400 seconds.")
                }
                return seconds
            }
            return Self.json(200, try await store.end(device, name: try Self.name(path[2]), dismissAfter: dismissAfter, now: now))
        default:
            throw APIError(.notFound, "No route for \(request.method) /\(path.joined(separator: "/")).")
        }
    }

    private static func route(_ path: [String]) -> String {
        switch path.count {
        case 3 where path[0] == "v1" && ["activities", "notifications"].contains(path[1]): "v1/\(path[1])/{name}"
        case 5 where path[0] == "v1" && path[1] == "device" && path[2] == "notifications" && path[4] == "report": "v1/device/notifications/{id}/report"
        case 6 where path[0] == "v1" && path[1] == "device" && path[2] == "notifications" && path[4] == "media": "v1/device/notifications/{id}/media/{media}"
        default: path.joined(separator: "/")
        }
    }

    private func waiting(_ seconds: Int, until done: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !(try await done()), ContinuousClock.now < deadline, !shutdown.isClosing {
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func now() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    private static func wait(_ request: HTTPRequest) throws -> Int {
        try request.query["wait"].map { text in
            guard let seconds = Int(text), (0...25).contains(seconds) else { throw invalid("wait must be 0 to 25 seconds.") }
            return seconds
        } ?? 0
    }

    private struct ActionPage: Encodable {
        let actions: [ActionRecord]
        let cursor: Int64
    }

    private func agent(_ request: HTTPRequest) async throws -> Device {
        guard let device = try await store.device(agentToken: try Self.bearer(request)) else { throw Self.unauthorized }
        return device
    }

    private func phone(_ request: HTTPRequest) async throws -> Device {
        guard let device = try await store.device(secret: try Self.bearer(request)) else { throw Self.unauthorized }
        return device
    }

    private static let unauthorized = APIError(.unauthorized, "Send Authorization: Bearer <token>.")

    private static func bearer(_ request: HTTPRequest) throws -> String {
        guard let value = request.headers["authorization"], value.hasPrefix("Bearer ") else { throw unauthorized }
        return String(value.dropFirst(7))
    }

    private static func notification(_ text: String) throws -> UUID {
        guard let id = UUID(uuidString: text) else { throw APIError(.notFound, "No notification has the id \(text).") }
        return id
    }

    private static func name(_ text: String) throws -> Name {
        guard let name = Name(rawValue: text) else {
            throw APIError(.invalidName, "Names use 1 to 64 lowercase letters, digits, '-', '_' or '.'.")
        }
        return name
    }

    private static func activityRequest(_ body: [UInt8]) throws -> ActivityRequest {
        guard case let .object(fields) = try decode(body) as JSONValue else { throw invalid("Send a JSON object.") }
        let allowed = Set(ActivityRequest.CodingKeys.allCases.map(\.rawValue))
        if let key = fields.keys.first(where: { !allowed.contains($0) }) {
            throw invalid("Unknown key \"\(key)\"; expected \(allowed.sorted().joined(separator: ", ")).")
        }
        let request: ActivityRequest = try decode(body)
        guard request.title.map({ (1...120).contains($0.count) }) != false else { throw invalid("title must be 1 to 120 characters.") }
        guard request.alert.map({ (1...200).contains($0.body.count) && ($0.title?.count ?? 0) <= 120 }) != false else {
            throw invalid("alert title must be at most 120 characters and body 1 to 200.")
        }
        let lifetime = Store.activityLifetime
        guard request.staleAfter.map({ (1...lifetime).contains($0) }) != false else { throw invalid("staleAfter must be 1 to \(lifetime) seconds.") }
        guard request.endAfter.map({ (1...lifetime).contains($0) }) != false else { throw invalid("endAfter must be 1 to \(lifetime) seconds.") }
        guard request.relevance.map({ (0...100).contains($0) }) != false else { throw invalid("relevance must be 0 to 100.") }
        guard request.ifRevision.map({ $0 >= 1 }) != false else { throw invalid("ifRevision must be a revision from GET /v1/activities/{name}.") }
        let paths = request.now?.keys.sorted() ?? []
        if let path = paths.first(where: { !(1...256).contains($0.utf8.count) || $0.contains("{{") || $0.split(separator: ".", omittingEmptySubsequences: false).contains("") }) {
            throw invalid("now: \"\(path)\" is not a data path such as \"timer.ends\".")
        }
        if let (outer, inner) = paths.lazy.flatMap({ outer in paths.lazy.filter { $0.hasPrefix(outer + ".") }.map { (outer, $0) } }).first {
            throw invalid("now: \"\(outer)\" contains \"\(inner)\"; set each value once.")
        }
        guard request.now?.values.allSatisfy(\.isFinite) != false else { throw invalid("now takes finite numbers of seconds.") }
        return request
    }

    private static func cursor(_ request: HTTPRequest, of record: String) throws -> Int64? {
        try request.query["after"].map { text in
            guard let seq = Int64(text), seq >= 0 else { throw invalid("after must be an \(record) seq.") }
            return seq
        }
    }

    private static func invalid(_ message: String) -> APIError {
        APIError(.invalidRequest, message)
    }

    private static func decode<T: Decodable>(_ body: [UInt8]) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(body))
        } catch let error as DecodingError {
            throw invalid(LayoutError(error).description)
        }
    }

    fileprivate static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return HTTPResponse(status: status, contentType: "application/json", body: Array(try! encoder.encode(value)))
    }
}

extension HTTPResponse {
    init(_ error: APIError) {
        self = API.json(error.code.status, error)
        if let retryAfter = error.retryAfter { headers["retry-after"] = String(retryAfter) }
    }
}

struct ActionRecord: Encodable, Sendable {
    let seq: Int64
    let activity: Name
    let input: Action.Input
    let at: Date

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(seq, forKey: .seq)
        try fields.encode(activity, forKey: .activity)
        try input.encode(to: encoder)
        try fields.encode(at, forKey: .at)
    }

    private enum CodingKeys: String, CodingKey {
        case seq, activity, at
    }
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
