public struct Name: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".utf8)
        guard (1...64).contains(rawValue.utf8.count), rawValue.utf8.allSatisfy(allowed.contains) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

