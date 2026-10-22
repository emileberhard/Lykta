import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import LyktaCore
import SwiftASN1
@_spi(FixedExpiryValidationTime) import X509

struct Enrolment: Sendable {
    static let challengeLifetime = 300

    let appID: String
    private let key = SymmetricKey(size: .bits256)

    init(appID: String) {
        self.appID = appID
    }

    func challenge(now: Int) -> Data {
        var issued = withUnsafeBytes(of: Int64(now).bigEndian) { Data($0) }
        var generator = SystemRandomNumberGenerator()
        issued += Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return issued + Data(HMAC<SHA256>.authenticationCode(for: issued, using: key))
    }

    func verify(keyID: Data, object: Data, challenge: Data, now: Int) async throws(APIError) {
        let issued = challenge.prefix(24)
        guard challenge.count == 56, HMAC<SHA256>.isValidAuthenticationCode(challenge.suffix(32), authenticating: issued, using: key) else {
            throw APIError(.registrationRefused, "The challenge did not come from this gateway. Ask for a new one.")
        }
        let time = issued.prefix(8).reduce(0) { $0 << 8 | Int($1) }
        guard (now - Self.challengeLifetime...now + 30).contains(time) else {
            throw APIError(.registrationRefused, "The challenge expired. Ask for a new one.")
        }
        do {
            try await AppAttest.verify(object, keyID: keyID, clientDataHash: Data(SHA256.hash(data: challenge)), appID: appID,
                                       at: Date(timeIntervalSince1970: Double(now)))
        } catch {
            throw APIError(.registrationRefused, "The app could not prove it is a genuine Lykta install: \(error.reason).")
        }
    }
}

struct AttestationError: Error {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }
}

enum AppAttest {
    private static let root = try! Certificate(pemEncoded: """
        -----BEGIN CERTIFICATE-----
        MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
        JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
        QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
        Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
        biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
        bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
        NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
        Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
        MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
        CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
        53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
        oyFraWVIyd/dganmrduC1bmTBGwD
        -----END CERTIFICATE-----
        """)
    private static let nonceExtension: ASN1ObjectIdentifier = [1, 2, 840, 113635, 100, 8, 2]
    private static let environments: Set<Data> = [Data("appattestdevelop".utf8), Data("appattest".utf8) + Data(count: 7)]

    static func verify(_ object: Data, keyID: Data, clientDataHash: Data, appID: String, at time: Date) async throws(AttestationError) {
        guard object.count <= 16 << 10, keyID.count == 32 else { throw AttestationError("the key or attestation has the wrong size") }
        var reader = CBORReader(object)
        guard case let .map(fields) = try reader.value(), reader.isAtEnd, case .text("apple-appattest") = fields["fmt"],
              case let .map(statement) = fields["attStmt"], case let .array(chain) = statement["x5c"], !chain.isEmpty,
              case let .bytes(authData) = fields["authData"] else {
            throw AttestationError("the attestation is not an App Attest object")
        }
        let certificates: [Certificate]
        do {
            certificates = try chain.map { value in
                guard case let .bytes(der) = value else { throw AttestationError("x5c holds something other than certificates") }
                return try Certificate(derEncoded: Array(der))
            }
        } catch {
            throw AttestationError("its certificates are unreadable")
        }
        var verifier = Verifier(rootCertificates: CertificateStore([root])) { RFC5280Policy(fixedExpiryValidationTime: time) }
        guard case .validCertificate = await verifier.validate(leaf: certificates[0], intermediates: CertificateStore(certificates.dropFirst())) else {
            throw AttestationError("its certificate does not lead to Apple's App Attest root")
        }
        let nonce = Array(SHA256.hash(data: authData + clientDataHash))
        guard certificates[0].extensions[oid: nonceExtension]?.value.elementsEqual([0x30, 0x24, 0xA1, 0x22, 0x04, 0x20] + nonce) == true else {
            throw AttestationError("it attests a different challenge")
        }
        guard let key = P256.Signing.PublicKey(certificates[0].publicKey), Data(SHA256.hash(data: key.x963Representation)) == keyID else {
            throw AttestationError("its certificate holds a different key")
        }
        let data = Array(authData)
        guard data.count >= 87, data[0..<32].elementsEqual(SHA256.hash(data: Data(appID.utf8))) else {
            throw AttestationError("it belongs to another app")
        }
        guard data[33..<37].allSatisfy({ $0 == 0 }), environments.contains(Data(data[37..<53])),
              data[53..<55].elementsEqual([0, 32]), data[55..<87].elementsEqual(keyID) else {
            throw AttestationError("its authenticator data does not describe a new App Attest key")
        }
    }
}

private indirect enum CBOR {
    case number(UInt64)
    case bytes(ArraySlice<UInt8>)
    case text(String)
    case array([CBOR])
    case map([String: CBOR])
}

private struct CBORReader {
    private var bytes: ArraySlice<UInt8>

    init(_ data: Data) {
        bytes = ArraySlice(data)
    }

    var isAtEnd: Bool { bytes.isEmpty }

    mutating func value(depth: Int = 0) throws(AttestationError) -> CBOR {
        guard depth < 8, let initial = bytes.popFirst() else { throw Self.malformed }
        let argument = try argument(initial & 0x1F)
        switch initial >> 5 {
        case 0:
            return .number(argument)
        case 2:
            return .bytes(try take(argument))
        case 3:
            guard let text = String(validating: try take(argument), as: UTF8.self) else { throw Self.malformed }
            return .text(text)
        case 4:
            guard argument <= bytes.count else { throw Self.malformed }
            var items: [CBOR] = []
            for _ in 0..<argument { items.append(try value(depth: depth + 1)) }
            return .array(items)
        case 5:
            guard argument <= bytes.count else { throw Self.malformed }
            var fields: [String: CBOR] = [:]
            for _ in 0..<argument {
                guard case let .text(key) = try value(depth: depth + 1) else { throw Self.malformed }
                fields[key] = try value(depth: depth + 1)
            }
            return .map(fields)
        default:
            throw Self.malformed
        }
    }

    private mutating func argument(_ info: UInt8) throws(AttestationError) -> UInt64 {
        switch info {
        case 0..<24: UInt64(info)
        case 24...27: try take(1 << (info - 24)).reduce(0) { $0 << 8 | UInt64($1) }
        default: throw Self.malformed
        }
    }

    private mutating func take(_ count: UInt64) throws(AttestationError) -> ArraySlice<UInt8> {
        guard count <= bytes.count else { throw Self.malformed }
        defer { bytes.removeFirst(Int(count)) }
        return bytes.prefix(Int(count))
    }

    private static let malformed = AttestationError("the attestation is not valid CBOR")
}
