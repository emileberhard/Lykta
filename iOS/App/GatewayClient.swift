import Foundation
import LyktaCore

struct AppError: LocalizedError {
    let status: Int?
    let errorDescription: String?
}

struct GatewayClient: Sendable {
    let url: URL

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

    func deleteDevice(secret: String) async throws {
        _ = try await send("DELETE", url.appending(path: "v1/device"), token: secret, body: nil)
    }

    func putActivity(_ name: String, _ request: JSONValue, agentToken: String) async throws {
        _ = try await send("PUT", url.appending(path: "v1/activities/\(name)"), token: agentToken, body: request)
    }

    func endActivity(_ name: String, agentToken: String) async throws {
        let target = url.appending(path: "v1/activities/\(name)").appending(queryItems: [URLQueryItem(name: "dismissAfter", value: "0")])
        do {
            _ = try await send("DELETE", target, token: agentToken, body: nil)
        } catch let error as AppError where error.status == 404 {}
    }

    private func send(_ method: String, _ target: URL, token: String?, body: (any Encodable)?) async throws -> Data {
        var request = URLRequest(url: target, timeoutInterval: 20)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Failure: Decodable { let message: String }
            throw AppError(status: status,
                           errorDescription: (try? JSONDecoder().decode(Failure.self, from: data).message) ?? "The gateway answered \(status).")
        }
        return data
    }
}
