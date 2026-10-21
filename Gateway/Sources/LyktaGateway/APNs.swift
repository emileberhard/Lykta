import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LyktaCore
import Synchronization

extension PushEnvironment {
    var pushOrigin: String {
        self == .production ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com"
    }

    var channelOrigin: String {
        self == .production ? "https://api-manage-broadcast.push.apple.com:2196" : "https://api-manage-broadcast.sandbox.push.apple.com:2195"
    }
}

enum APNsError: Error, Sendable, CustomStringConvertible {
    case rejected(status: Int, reason: String)
    case notSent(String)
    case unknown(String)

    var description: String {
        switch self {
        case let .rejected(status, reason): "APNs \(status) \(reason)"
        case let .notSent(detail): "APNs unreachable: \(detail)"
        case let .unknown(detail): "APNs outcome unknown: \(detail)"
        }
    }
}

protocol PushService: Sendable {
    var environments: Set<PushEnvironment> { get }
    func start(_ payload: Data, deviceToken: String, environment: PushEnvironment) async throws(APNsError)
    func broadcast(_ payload: Data, channel: String, priority: Int, environment: PushEnvironment) async throws(APNsError)
    func createChannel(environment: PushEnvironment) async throws(APNsError) -> String
    func deleteChannel(_ channel: String, environment: PushEnvironment) async throws(APNsError)
    func channels(environment: PushEnvironment) async throws(APNsError) -> [String]
}

final class APNs: PushService {
    let environments: Set<PushEnvironment>
    private let bundleID: String
    private let signers: [PushEnvironment: Signer]
    private let session: URLSession

    init(bundleID: String, teamID: String, keys: [PushEnvironment: (id: String, pem: String)]) throws {
        self.bundleID = bundleID
        signers = try keys.mapValues { try Signer(teamID: teamID, keyID: $0.id, pem: $0.pem) }
        environments = Set(keys.keys)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)
    }

    func start(_ payload: Data, deviceToken: String, environment: PushEnvironment) async throws(APNsError) {
        let headers = ["apns-topic": "\(bundleID).push-type.liveactivity", "apns-push-type": "liveactivity", "apns-priority": "10"]
        _ = try await send("POST", "\(environment.pushOrigin)/3/device/\(deviceToken)", environment, headers: headers, body: payload)
    }

    func broadcast(_ payload: Data, channel: String, priority: Int, environment: PushEnvironment) async throws(APNsError) {
        let headers = ["apns-channel-id": channel, "apns-push-type": "LiveActivity", "apns-priority": String(priority), "apns-expiration": "0"]
        _ = try await send("POST", "\(environment.pushOrigin)/4/broadcasts/apps/\(bundleID)", environment, headers: headers, body: payload)
    }

    func createChannel(environment: PushEnvironment) async throws(APNsError) -> String {
        let body = Data(#"{"message-storage-policy":0,"push-type":"LiveActivity"}"#.utf8)
        let (response, _) = try await send("POST", "\(environment.channelOrigin)/1/apps/\(bundleID)/channels", environment, headers: [:], body: body)
        guard let channel = response.value(forHTTPHeaderField: "apns-channel-id"), !channel.isEmpty else {
            throw .unknown("channel created without apns-channel-id")
        }
        return channel
    }

    func deleteChannel(_ channel: String, environment: PushEnvironment) async throws(APNsError) {
        _ = try await send("DELETE", "\(environment.channelOrigin)/1/apps/\(bundleID)/channels", environment,
                           headers: ["apns-channel-id": channel], body: nil)
    }

    func channels(environment: PushEnvironment) async throws(APNsError) -> [String] {
        struct List: Decodable { let channels: [String] }
        let (_, body) = try await send("GET", "\(environment.channelOrigin)/1/apps/\(bundleID)/all-channels", environment, headers: [:], body: nil)
        guard let list = try? JSONDecoder().decode(List.self, from: body) else { throw .unknown("unreadable channel list") }
        return list.channels
    }

    private func send(_ method: String, _ url: String, _ environment: PushEnvironment, headers: [String: String],
                      body: Data?) async throws(APNsError) -> (HTTPURLResponse, Data) {
        guard let signer = signers[environment] else { throw .notSent("no APNs key is configured for \(environment.rawValue)") }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("bearer \(try signer.token())", forHTTPHeaderField: "authorization")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet].contains(error.code) {
            throw .notSent(error.localizedDescription)
        } catch {
            throw .unknown(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .unknown("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { let reason: String }
            let reason = (try? JSONDecoder().decode(Failure.self, from: data).reason) ?? "Unknown"
            if reason == "ExpiredProviderToken" { signer.expire() }
            throw .rejected(status: http.statusCode, reason: reason)
        }
        return (http, data)
    }
}

private final class Signer: Sendable {
    private let header: String
    private let teamID: String
    private let key: P256.Signing.PrivateKey
    private let cached = Mutex<(value: String, issuedAt: ContinuousClock.Instant)?>(nil)

    init(teamID: String, keyID: String, pem: String) throws {
        header = Self.base64URL(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        self.teamID = teamID
        key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    func token() throws(APNsError) -> String {
        let value: String? = cached.withLock { cached in
            if let cached, cached.issuedAt.duration(to: .now) < .seconds(50 * 60) { return cached.value }
            let claims = Self.base64URL(Data(#"{"iss":"\#(teamID)","iat":\#(Int(Date().timeIntervalSince1970))}"#.utf8))
            guard let signature = try? key.signature(for: Data("\(header).\(claims)".utf8)) else { return nil }
            let value = "\(header).\(claims).\(Self.base64URL(signature.rawRepresentation))"
            cached = (value, .now)
            return value
        }
        guard let value else { throw .notSent("could not sign the provider token") }
        return value
    }

    func expire() {
        cached.withLock { $0 = nil }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
