import Foundation
import LyktaCore
import Security

enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "credentials",
    ]

    static func load() throws -> Credentials? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }

    static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(query as CFDictionary)
        let attributes = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    private static func failure(_ status: OSStatus) -> AppError {
        AppError(errorDescription: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
    }
}
