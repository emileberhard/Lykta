import Foundation
import LyktaCore

struct API: Sendable {
    let store: Store
    let environments: Set<PushEnvironment>

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        do {
            return try await route(request, now: Int(Date().timeIntervalSince1970))
        } catch let error as APIError {
            return Self.json(error.status, ["error": error.code, "message": error.message])
        } catch {
            log("\(request.method) /\(request.path.joined(separator: "/")) failed: \(error)")
            return Self.json(500, ["error": "internal", "message": "The gateway failed to handle the request."])
        }
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
                throw APIError(status: 400, code: "unsupported_environment",
                               message: "This gateway has no APNs key for \(registration.environment.rawValue) builds.")
            }
            let credentials = try await store.registerDevice(environment: registration.environment,
                                                             appVersion: String(registration.appVersion.prefix(32)), now: now)
            return Self.json(201, credentials)
        case ("PUT", "v1/device"):
            let device = try await phone(request)
            let report: DeviceReport = try Self.decode(request.body)
            try Self.validate(report)
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
                    throw APIError(status: 400, code: "invalid_request", message: "dismissAfter must be 0 to 14400 seconds.")
                }
                return seconds
            }
            return Self.json(200, try await store.end(device, name: try Self.name(path[2]), dismissAfter: dismissAfter, now: now))
        default:
            throw APIError(status: 404, code: "not_found", message: "No route for \(request.method) /\(path.joined(separator: "/")).")
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

    private static let unauthorized = APIError(status: 401, code: "unauthorized", message: "Send Authorization: Bearer <token>.")

    private static func bearer(_ request: HTTPRequest) throws -> String {
        guard let value = request.headers["authorization"], value.hasPrefix("Bearer ") else { throw unauthorized }
        return String(value.dropFirst(7))
    }

    private static func name(_ name: String) throws -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".utf8)
        guard (1...64).contains(name.utf8.count), name.utf8.allSatisfy(allowed.contains) else {
            throw APIError(status: 400, code: "invalid_name", message: "Names use 1 to 64 lowercase letters, digits, '-', '_' or '.'.")
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

    private static func validate(_ report: DeviceReport) throws {
        let hex = Set("0123456789abcdef".utf8)
        let states: Set = ["pending", "active", "stale", "ended", "dismissed", "unknown"]
        guard report.pushToStartToken.map({ (1...256).contains($0.utf8.count) && $0.utf8.allSatisfy(hex.contains) }) != false,
              report.appVersion.count <= 32, report.bundleInstance.count <= 64, report.activities.count <= 64,
              report.activities.allSatisfy({ $0.id.count <= 64 && states.contains($0.state) })
        else { throw invalid("The device report is malformed.") }
    }

    private static func invalid(_ message: String) -> APIError {
        APIError(status: 400, code: "invalid_request", message: message)
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
