import Foundation
import LyktaCore

struct API: Sendable {
    let store: Store
    let environments: Set<PushEnvironment>

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let failure: APIError
        do {
            return try await route(request, now: Int(Date().timeIntervalSince1970))
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
        return Self.json(failure.code.status, failure)
    }

    private static let skill: [String: HTTPResponse] = [
        "skill/SKILL.md": PackageResources.SKILL_md,
        "skill/references/layout.md": PackageResources.layout_md,
    ].mapValues { HTTPResponse(status: 200, contentType: "text/markdown; charset=utf-8", body: $0) }.merging([
        "skill/examples/agent-question.json": PackageResources.agent_question_json,
        "skill/examples/app-review.json": PackageResources.app_review_json,
        "skill/examples/homelab.json": PackageResources.homelab_json,
        "skill/examples/jira-release.json": PackageResources.jira_release_json,
        "skill/examples/movie-night.json": PackageResources.movie_night_json,
        "skill/examples/orion-return.json": PackageResources.orion_return_json,
        "skill/examples/pr-inbox.json": PackageResources.pr_inbox_json,
        "skill/examples/printer.json": PackageResources.printer_json,
        "skill/examples/puppy-potty.json": PackageResources.puppy_potty_json,
        "skill/examples/recipe-steps.json": PackageResources.recipe_steps_json,
        "skill/examples/shopping-list.json": PackageResources.shopping_list_json,
        "skill/examples/solar-eclipse.json": PackageResources.solar_eclipse_json,
    ].mapValues { HTTPResponse(status: 200, contentType: "application/json", body: $0) }) { $1 }

    private func route(_ request: HTTPRequest, now: Int) async throws -> HTTPResponse {
        let path = request.path
        if request.method == "GET", let file = Self.skill[path.joined(separator: "/")] {
            return file
        }
        let isActivity = path.count == 3 && path[0] == "v1" && path[1] == "activities"
        switch (request.method, isActivity ? "v1/activities/{name}" : path.joined(separator: "/")) {
        case ("POST", "v1/devices"):
            let registration: Registration = try Self.decode(request.body)
            guard environments.contains(registration.environment) else {
                throw APIError(.unsupportedEnvironment, "This gateway has no APNs key for \(registration.environment.rawValue) builds.")
            }
            let credentials = try await store.registerDevice(environment: registration.environment, appVersion: registration.appVersion, now: now)
            return Self.json(201, credentials)
        case ("PUT", "v1/device"):
            let device = try await phone(request)
            let report: DeviceReport = try Self.decode(request.body)
            return Self.json(200, SyncResult(end: try await store.sync(device, report: report, now: now)))
        case ("DELETE", "v1/device"):
            try await store.deleteDevice(try await phone(request))
            return HTTPResponse(status: 204, contentType: "text/plain", body: [])
        case ("POST", "v1/device/actions"):
            let device = try await phone(request)
            try await store.act(device, try Self.decode(request.body), now: now)
            return HTTPResponse(status: 204, contentType: "text/plain", body: [])
        case ("GET", "v1/actions"):
            let device = try await agent(request)
            let wait = try request.query["wait"].map { text in
                guard let seconds = Int(text), (0...25).contains(seconds) else { throw Self.invalid("wait must be 0 to 25 seconds.") }
                return seconds
            } ?? 0
            let after = try request.query["after"].map { text in
                guard let seq = Int64(text), seq >= 0 else { throw Self.invalid("after must be an action seq.") }
                return seq
            }
            let cursor = if let after { after } else { try await store.latestAction(device) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(wait))
            while true {
                let actions = try await store.actions(device, after: cursor, limit: 100)
                if !actions.isEmpty || ContinuousClock.now >= deadline {
                    return Self.json(200, ActionPage(actions: actions, cursor: actions.last?.seq ?? cursor))
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        case ("POST", "v1/device/events"):
            let device = try await phone(request)
            try await store.ingest(device, try Self.decode(request.body))
            return HTTPResponse(status: 204, contentType: "text/plain", body: [])
        case ("GET", "v1/events"):
            let device = try await agent(request)
            let after = try request.query["after"].map { text in
                guard let seq = Int64(text), seq >= 0 else { throw Self.invalid("after must be an event seq.") }
                return seq
            }
            let limit = try request.query["limit"].map { text in
                guard let limit = Int(text), (1...1000).contains(limit) else { throw Self.invalid("limit must be 1 to 1000.") }
                return limit
            } ?? 200
            return Self.json(200, ["events": try await store.events(device: device.id, after: after, limit: limit)])
        case ("GET", "v1/activities"):
            return Self.json(200, ["activities": try await store.list(try await agent(request))])
        case ("GET", "v1/activities/{name}"):
            return Self.json(200, try await store.detail(try await agent(request), name: try Self.name(path[2])))
        case ("PUT", "v1/activities/{name}"):
            let device = try await agent(request)
            let status = try await store.put(device, name: try Self.name(path[2]), request: try Self.activityRequest(request.body), now: now)
            return Self.json(200, status)
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

    private static func name(_ text: String) throws -> ActivityName {
        guard let name = ActivityName(rawValue: text) else {
            throw APIError(.invalidName, "Names use 1 to 64 lowercase letters, digits, '-', '_' or '.'.")
        }
        return name
    }

    private static func activityRequest(_ body: [UInt8]) throws -> ActivityRequest {
        struct Body: Decodable {
            let title: String?
            let layout: JSONValue?
            let data: JSONValue?
            let alert: Alert?
            let staleAfter: Int?
            let endAfter: Int?
            let relevance: Double?
            let ifRevision: Int?
        }
        guard case let .object(fields) = try decode(body) as JSONValue else { throw invalid("Send a JSON object.") }
        let allowed: Set = ["title", "layout", "data", "alert", "staleAfter", "endAfter", "relevance", "ifRevision"]
        if let key = fields.keys.first(where: { !allowed.contains($0) }) {
            throw invalid("Unknown key \"\(key)\"; expected \(allowed.sorted().joined(separator: ", ")).")
        }
        let request: Body = try decode(body)
        guard request.title.map({ (1...120).contains($0.count) }) != false else { throw invalid("title must be 1 to 120 characters.") }
        guard request.alert.map({ (1...200).contains($0.body.count) && ($0.title?.count ?? 0) <= 120 }) != false else {
            throw invalid("alert title must be at most 120 characters and body 1 to 200.")
        }
        guard request.staleAfter.map({ (1...8 * 3600).contains($0) }) != false else { throw invalid("staleAfter must be 1 to 28800 seconds.") }
        guard request.endAfter.map({ (1...8 * 3600).contains($0) }) != false else { throw invalid("endAfter must be 1 to 28800 seconds.") }
        guard request.relevance.map({ (0...100).contains($0) }) != false else { throw invalid("relevance must be 0 to 100.") }
        guard request.ifRevision.map({ $0 >= 1 }) != false else { throw invalid("ifRevision must be a revision from GET /v1/activities/{name}.") }
        return ActivityRequest(title: request.title, layout: request.layout, data: request.data, alert: request.alert,
                               staleAfter: request.staleAfter, endAfter: request.endAfter, relevance: request.relevance,
                               ifRevision: request.ifRevision)
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

    private static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return HTTPResponse(status: status, contentType: "application/json", body: Array(try! encoder.encode(value)))
    }
}
