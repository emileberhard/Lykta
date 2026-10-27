import Foundation
import LyktaCore
import Security

nonisolated struct KeychainItem<Value: Codable>: Sendable {
    private let service: String
    private let accessGroup: String?

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            .merging(accessGroup.map { [kSecAttrAccessGroup as String: $0] } ?? [:]) { $1 }
    }

    func load() throws -> Value? {
        var result: AnyObject?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.failure(status) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    private static func failure(_ status: OSStatus) -> AppError {
        AppError(status: nil, errorDescription: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)")
    }
}

nonisolated extension KeychainItem<Credentials> {
    static let credentials = KeychainItem(service: "credentials", accessGroup: nil)
}

nonisolated extension KeychainItem<WidgetCredential> {
    static let widget = KeychainItem(service: "widget", accessGroup: AppGroup.identifier)
}

nonisolated enum AppGroup {
    static let identifier: String = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LyktaAppGroup") as? String, !group.isEmpty else {
            preconditionFailure("Info.plist needs LyktaAppGroup")
        }
        return group
    }()

    static var container: URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            preconditionFailure("\(Bundle.main.bundleIdentifier ?? "This bundle") is not signed with \(identifier)")
        }
        return container
    }

    static func lockingWidgets<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let directory = container.appending(path: "Library/Application Support/Widgets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appending(path: "widgets.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body(directory)
    }
}
