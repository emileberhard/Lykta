import Foundation
import LyktaCore

struct AppError: LocalizedError {
    let errorDescription: String?
}

struct GatewayClient: Sendable {
    let url: URL

    func register(_ registration: Registration) async throws -> Credentials {
        try JSONDecoder().decode(Credentials.self, from: await send("POST", "v1/devices", token: nil, body: registration))
    }

    func sync(_ report: DeviceReport, secret: String) async throws -> SyncResult {
        try JSONDecoder().decode(SyncResult.self, from: await send("PUT", "v1/device", token: secret, body: report))
    }

    func deleteDevice(secret: String) async throws {
        _ = try await send("DELETE", "v1/device", token: secret, body: nil)
    }

    func putActivity(_ name: String, title: String, layout: JSONValue, data: JSONValue, agentToken: String) async throws {
        let body = JSONValue.object(["title": .string(title), "layout": layout, "data": data])
        _ = try await send("PUT", "v1/activities/\(name)", token: agentToken, body: body)
    }

    private func send(_ method: String, _ path: String, token: String?, body: (any Encodable)?) async throws -> Data {
        var request = URLRequest(url: url.appending(path: path), timeoutInterval: 20)
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
            throw AppError(errorDescription: (try? JSONDecoder().decode(Failure.self, from: data).message) ?? "The gateway answered \(status).")
        }
        return data
    }
}
