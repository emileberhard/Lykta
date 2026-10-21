import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var json: [UInt8] {
        Array(try! JSONEncoder().encode(self))
    }

    public func filled(with data: JSONValue) throws(LayoutError) -> JSONValue {
        try filled(with: data, path: "")
    }

    private func filled(with data: JSONValue, path: String) throws(LayoutError) -> JSONValue {
        switch self {
        case let .object(fields):
            var filled: [String: JSONValue] = [:]
            for (key, value) in fields { filled[key] = try value.filled(with: data, path: path.isEmpty ? key : "\(path).\(key)") }
            return .object(filled)
        case let .array(items):
            var filled: [JSONValue] = []
            for (index, item) in items.enumerated() { filled.append(try item.filled(with: data, path: "\(path)[\(index)]")) }
            return .array(filled)
        case let .string(text) where text.contains("{{"):
            return try Self.fill(text, with: data, path: path)
        case .string, .number, .bool, .null:
            return self
        }
    }

    private static func fill(_ text: String, with data: JSONValue, path: String) throws(LayoutError) -> JSONValue {
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { throw LayoutError("\(path): unclosed {{") }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = try lookup(key, in: data, path: path)
            if output.isEmpty, open.lowerBound == rest.startIndex, close.upperBound == rest.endIndex { return value }
            output += rest[..<open.lowerBound]
            switch value {
            case let .string(string): output += string
            case let .number(number): output += number == number.rounded() && abs(number) < 1e15 ? String(Int64(number)) : String(number)
            case let .bool(bool): output += String(bool)
            case .null: throw LayoutError("\(path): data \"\(key)\" is null and cannot be inserted into text")
            case .array, .object: throw LayoutError("\(path): data \"\(key)\" is not a single value")
            }
            rest = rest[close.upperBound...]
        }
        return .string(output + rest)
    }

    private static func lookup(_ key: String, in data: JSONValue, path: String) throws(LayoutError) -> JSONValue {
        var value = data
        for part in key.split(separator: ".", omittingEmptySubsequences: false) {
            switch value {
            case let .object(fields) where fields[String(part)] != nil: value = fields[String(part)]!
            case let .array(items) where Int(part).map(items.indices.contains) == true: value = items[Int(part)!]
            default: throw LayoutError("\(path): data has no value at \"\(key)\"")
            }
        }
        switch value {
        case .array, .object: throw LayoutError("\(path): data \"\(key)\" is not a single value")
        case .string, .number, .bool, .null: return value
        }
    }
}
