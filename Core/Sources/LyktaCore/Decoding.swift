import Foundation

public struct LayoutError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }

    public init(_ error: DecodingError) {
        let (context, detail): (DecodingError.Context, String) = switch error {
        case let .keyNotFound(key, context): (context, "missing \"\(key.stringValue)\"")
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .dataCorrupted(context):
            (context, context.debugDescription)
        @unknown default: (DecodingError.Context(codingPath: [], debugDescription: ""), "\(error)")
        }
        let path = Self.path(context.codingPath)
        description = path.isEmpty ? detail : "\(path): \(detail)"
    }

    static func path(_ codingPath: [any CodingKey]) -> String {
        codingPath.reduce("") { path, key in
            if let index = key.intValue { "\(path)[\(index)]" } else if path.isEmpty { key.stringValue } else { "\(path).\(key.stringValue)" }
        }
    }
}

public protocol Choice: RawRepresentable<String>, CaseIterable, Decodable, Sendable {}

extension Choice {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            let cases = Self.allCases.map(\.rawValue).joined(separator: ", ")
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\"\(raw)\" is not one of \(cases)")
        }
        let type = String(reflecting: Self.self)
        FeatureLog.record("\(type.hasPrefix("LyktaCore.") ? String(type.dropFirst(10)) : type).\(raw)", at: container.codingPath)
        self = value
    }
}

struct Key: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

typealias Fields = KeyedDecodingContainer<Key>

extension KeyedDecodingContainer<Key> {
    func required<T: Decodable>(_ key: String) throws -> T {
        try decode(T.self, forKey: Key(stringValue: key))
    }

    func optional<T: Decodable>(_ key: String) throws -> T? {
        try decodeIfPresent(T.self, forKey: Key(stringValue: key))
    }

    func text(_ key: String, maximumLength: Int) throws -> String {
        let value: String = try required(key)
        guard value.count <= maximumLength else { throw invalid("must be at most \(maximumLength) characters", at: key) }
        return value
    }

    func number(_ key: String, in range: ClosedRange<Double>) throws -> Double {
        let value: Double = try required(key)
        guard range.contains(value) else { throw invalid("must be between \(range.lowerBound) and \(range.upperBound)", at: key) }
        return value
    }

    func allowOnly(_ keys: Set<String>) throws {
        if let key = allKeys.first(where: { !keys.contains($0.stringValue) }) {
            throw invalid("unknown key; expected \(keys.sorted().joined(separator: ", "))", at: key.stringValue)
        }
    }

    func invalid(_ message: String, at key: String? = nil) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath + (key.map { [Key(stringValue: $0)] } ?? []), debugDescription: message))
    }
}
