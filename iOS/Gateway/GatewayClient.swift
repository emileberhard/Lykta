import Foundation
import LyktaCore

nonisolated struct AppError: LocalizedError {
    let status: Int?
    let errorDescription: String?
}

nonisolated enum WidgetAnswer: Sendable {
    case snapshot(WidgetSnapshot)
    case unchanged
    case deleted
    case signedOut
}

nonisolated struct GatewayClient: Sendable {
    let url: URL
    let timeout: TimeInterval

    static func configured(timeout: TimeInterval) -> GatewayClient? {
        let host = Bundle.main.object(forInfoDictionaryKey: "LyktaGatewayHost") as? String ?? ""
        return host.isEmpty ? nil : URL(string: "https://\(host)").map { GatewayClient(url: $0, timeout: timeout) }
    }

    func challenge() async throws -> Data {
        try JSONDecoder().decode(Challenge.self, from: await send("GET", url.appending(path: "v1/devices/challenge"), token: nil, body: nil)).challenge
    }

    func register(_ registration: Registration) async throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: await send("POST", url.appending(path: "v1/devices"), token: nil, body: registration))
    }

    func sync(_ report: DeviceReport, secret: String) async throws -> SyncResult {
        try JSONDecoder().decode(SyncResult.self, from: await send("PUT", url.appending(path: "v1/device"), token: secret, body: report))
    }

    func upload(_ batch: EventBatch, secret: String) async throws {
        _ = try await send("POST", url.appending(path: "v1/device/events"), token: secret, body: batch)
    }

    func act(_ action: Action, secret: String) async throws {
        _ = try await send("POST", url.appending(path: "v1/device/actions"), token: secret, body: action)
    }

    func end(_ activity: UUID, secret: String) async throws {
        _ = try await send("DELETE", url.appending(path: "v1/device/activities/\(activity)"), token: secret, body: nil)
    }

    func deleteDevice(secret: String) async throws {
        _ = try await send("DELETE", url.appending(path: "v1/device"), token: secret, body: nil)
    }

    func createWidgetCredential(secret: String) async throws -> WidgetCredential {
        try JSONDecoder().decode(WidgetCredential.self, from: await send("POST", url.appending(path: "v1/device/widgets/credential"), token: secret, body: nil))
    }

    func report(_ report: WidgetReport, widgetToken: String) async throws {
        _ = try await send("PUT", url.appending(path: "v1/device/widgets"), token: widgetToken, body: report)
    }

    func widgets(widgetToken: String) async throws -> [WidgetSummary] {
        struct List: Decodable { let widgets: [WidgetSummary] }
        return try JSONDecoder().decode(List.self, from: await send("GET", url.appending(path: "v1/device/widgets"), token: widgetToken, body: nil)).widgets
    }

    func widget(_ id: UUID, family: WidgetLayout.Family, have revision: Int?, widgetToken: String) async throws -> WidgetAnswer {
        let query = [URLQueryItem(name: "family", value: family.rawValue), URLQueryItem(name: "layout", value: Layout.version.description)]
            + (revision.map { [URLQueryItem(name: "have", value: String($0))] } ?? [])
        let target = url.appending(path: "v1/device/widgets/\(id.uuidString.lowercased())").appending(queryItems: query)
        let (data, status) = try await exchange("GET", target, token: widgetToken, body: nil, type: "application/json")
        switch status {
        case 200: return .snapshot(try JSONDecoder().decode(WidgetSnapshot.self, from: data))
        case 204: return .unchanged
        case 401: return .signedOut
        case 410: return .deleted
        default: throw Self.failure(status, data)
        }
    }

    func putActivity(_ name: String, _ request: JSONValue, agentToken: String) async throws {
        _ = try await send("PUT", url.appending(path: "v1/activities/\(name)"), token: agentToken, body: request)
    }

    func putWidget(_ name: String, _ request: JSONValue, agentToken: String) async throws {
        _ = try await send("PUT", url.appending(path: "v1/widgets/\(name)"), token: agentToken, body: request)
    }

    func upload(_ medium: Data, agentToken: String) async throws -> MediaID {
        struct Uploaded: Decodable { let id: MediaID }
        let response = try await send("POST", url.appending(path: "v1/media"), token: agentToken, body: medium, type: "application/octet-stream")
        return try JSONDecoder().decode(Uploaded.self, from: response).id
    }

    func putNotification(_ name: String, _ request: JSONValue, agentToken: String) async throws {
        _ = try await send("PUT", url.appending(path: "v1/notifications/\(name)"), token: agentToken, body: request)
    }

    func endActivity(_ name: String, agentToken: String) async throws {
        let target = url.appending(path: "v1/activities/\(name)").appending(queryItems: [URLQueryItem(name: "dismissAfter", value: "0")])
        do {
            _ = try await send("DELETE", target, token: agentToken, body: nil)
        } catch let error as AppError where error.status == 404 {}
    }

    private func send(_ method: String, _ target: URL, token: String?, body: (any Encodable)?) async throws -> Data {
        try await send(method, target, token: token, body: try body.map { try JSONEncoder().encode($0) }, type: "application/json")
    }

    private func send(_ method: String, _ target: URL, token: String?, body: Data?, type: String) async throws -> Data {
        let (data, status) = try await exchange(method, target, token: token, body: body, type: type)
        guard (200..<300).contains(status) else { throw Self.failure(status, data) }
        return data
    }

    private func exchange(_ method: String, _ target: URL, token: String?, body: Data?, type: String) async throws -> (Data, Int) {
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue(type, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { [request] in try await URLSession.shared.data(for: request) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func failure(_ status: Int, _ data: Data) -> AppError {
        struct Failure: Decodable { let message: String }
        return AppError(status: status, errorDescription: (try? JSONDecoder().decode(Failure.self, from: data).message) ?? "The gateway answered \(status).")
    }
}
