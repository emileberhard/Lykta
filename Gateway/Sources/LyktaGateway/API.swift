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
        return Self.json(failure.code.status, failure)
    }

    private func route(_ request: HTTPRequest, now: Int) async throws -> HTTPResponse {
        let path = request.path
        let isActivity = path.count == 3 && path[0] == "v1" && path[1] == "activities"
        switch (request.method, isActivity ? "v1/activities/{name}" : path.joined(separator: "/")) {
        case ("GET", "skill/SKILL.md"):
            return HTTPResponse(status: 200, contentType: "text/markdown; charset=utf-8", body: PackageResources.SKILL_md)
        case ("GET", "skill/references/layout.md"):
            return HTTPResponse(status: 200, contentType: "text/markdown; charset=utf-8", body: PackageResources.layout_md)
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
        case ("GET", "v1/activities"):
            return Self.json(200, ["activities": try await store.list(try await agent(request))])
        case ("GET", "v1/activities/{name}"):
            return Self.json(200, try await store.status(try await agent(request), name: try Self.name(path[2])))
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
            let relevance: Double?
        }
        guard case let .object(fields) = try decode(body) as JSONValue else { throw invalid("Send a JSON object.") }
        let allowed: Set = ["title", "layout", "data", "alert", "staleAfter", "relevance"]
        if let key = fields.keys.first(where: { !allowed.contains($0) }) {
            throw invalid("Unknown key \"\(key)\"; expected \(allowed.sorted().joined(separator: ", ")).")
        }
        let request: Body = try decode(body)
        guard request.title.map({ (1...120).contains($0.count) }) != false else { throw invalid("title must be 1 to 120 characters.") }
        guard request.alert.map({ $0.body.count <= 200 && ($0.title?.count ?? 0) <= 120 }) != false else {
            throw invalid("alert title and body must be at most 120 and 200 characters.")
        }
        guard request.staleAfter.map({ (1...8 * 3600).contains($0) }) != false else { throw invalid("staleAfter must be 1 to 28800 seconds.") }
        guard request.relevance.map({ (0...100).contains($0) }) != false else { throw invalid("relevance must be 0 to 100.") }
        return ActivityRequest(title: request.title, layout: request.layout, data: request.data, alert: request.alert,
                               staleAfter: request.staleAfter, relevance: request.relevance)
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
