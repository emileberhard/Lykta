import Foundation

extension JSONValue {
    public func filled(with data: JSONValue) throws(LayoutError) -> JSONValue {
        var template = Template(data: data)
        return try template.fill(self, at: "", in: [:])
    }

    public func replacing(_ path: String, with value: JSONValue) throws(LayoutError) -> JSONValue {
        try replacing(path.split(separator: ".", omittingEmptySubsequences: false)[...], with: value, path: path)
    }

    private func replacing(_ parts: ArraySlice<Substring>, with value: JSONValue, path: String) throws(LayoutError) -> JSONValue {
        guard let part = parts.first else { return value }
        switch self {
        case var .object(fields) where fields[String(part)] != nil:
            fields[String(part)] = try fields[String(part)]!.replacing(parts.dropFirst(), with: value, path: path)
            return .object(fields)
        case var .array(items) where Int(part).map(items.indices.contains) == true:
            items[Int(part)!] = try items[Int(part)!].replacing(parts.dropFirst(), with: value, path: path)
            return .array(items)
        default:
            throw LayoutError("data has no value at \"\(path)\"")
        }
    }
}

private struct Template {
    let data: JSONValue
    var repeated = 0

    mutating func fill(_ value: JSONValue, at path: String, in scope: [String: String]) throws(LayoutError) -> JSONValue {
        switch value {
        case let .object(fields):
            guard fields["each"] == nil else { throw LayoutError("\(path): each must be an item in a list") }
            var filled: [String: JSONValue] = [:]
            for (key, value) in fields where key != "toggle" {
                filled[key] = try fill(value, at: Self.join(path, key), in: scope)
            }
            if let binding = fields["toggle"] {
                filled.merge(try bind(binding, at: path, in: scope, existing: filled)) { $1 }
            }
            return .object(filled)
        case let .array(items):
            var filled: [JSONValue] = []
            for (index, item) in items.enumerated() {
                if case let .object(fields) = item, fields["each"] != nil {
                    filled += try repeating(fields, at: "\(path)[\(index)]", in: scope)
                } else {
                    filled.append(try fill(item, at: "\(path)[\(index)]", in: scope))
                }
            }
            return .array(filled)
        case let .string(text) where text.contains("{{"):
            return try substitute(text, at: path, in: scope)
        case .string, .number, .bool, .null:
            return value
        }
    }

    private mutating func repeating(_ fields: [String: JSONValue], at path: String, in scope: [String: String]) throws(LayoutError) -> [JSONValue] {
        guard Set(fields.keys) == ["each", "as", "do"], case let .string(source) = fields["each"], case let .string(name) = fields["as"],
              let item = fields["do"] else {
            throw LayoutError(#"\#(path): expected {"each": "list.path", "as": "name", "do": item}"#)
        }
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
            throw LayoutError("\(path).as: a name starts with a letter and has only letters, digits and _")
        }
        let list = Self.resolve(source, in: scope)
        guard case let .array(items) = try self.value(at: list, for: "\(path).each") else {
            throw LayoutError("\(path).each: data \"\(source)\" is not a list")
        }
        repeated += items.count
        guard repeated <= Layout.maximumNodes else { throw LayoutError("each repeats more than \(Layout.maximumNodes) items") }
        var filled: [JSONValue] = []
        for index in items.indices {
            filled.append(try fill(item, at: "\(path).do", in: scope.merging([name: "\(list).\(index)"]) { $1 }))
        }
        return filled
    }

    private func bind(_ binding: JSONValue, at path: String, in scope: [String: String],
                      existing: [String: JSONValue]) throws(LayoutError) -> [String: JSONValue] {
        guard existing["isOn"] == nil else {
            throw LayoutError("\(Self.join(path, "isOn")): a toggle reads isOn from the data at its path")
        }
        guard case let .string(source) = binding, !source.isEmpty, !source.contains("{{") else {
            throw LayoutError("\(Self.join(path, "toggle")): expected a data path such as \"items.0.done\"")
        }
        let target = Self.resolve(source, in: scope)
        guard case let .bool(isOn) = try value(at: target, for: Self.join(path, "toggle")) else {
            throw LayoutError("\(Self.join(path, "toggle")): data \"\(target)\" must be true or false")
        }
        return ["toggle": .string(target), "isOn": .bool(isOn)]
    }

    private func substitute(_ text: String, at path: String, in scope: [String: String]) throws(LayoutError) -> JSONValue {
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { throw LayoutError("\(path): unclosed {{") }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = try value(at: Self.resolve(key, in: scope), for: path)
            if output.isEmpty, open.lowerBound == rest.startIndex, close.upperBound == rest.endIndex { return value }
            output += rest[..<open.lowerBound]
            switch value {
            case let .string(string): output += path == "svg" || path.hasSuffix(".svg") ? Self.escaped(string) : string
            case let .number(number): output += number.textValue
            case let .bool(bool): output += String(bool)
            case .null: throw LayoutError("\(path): data \"\(key)\" is null and cannot be inserted into text")
            case .array, .object: throw LayoutError("\(path): data \"\(key)\" is not a single value and cannot be inserted into text")
            }
            rest = rest[close.upperBound...]
        }
        return .string(output + rest)
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;").replacing("'", with: "&apos;")
    }

    private func value(at key: String, for path: String) throws(LayoutError) -> JSONValue {
        var value = data
        for part in key.split(separator: ".", omittingEmptySubsequences: false) {
            switch value {
            case let .object(fields) where fields[String(part)] != nil: value = fields[String(part)]!
            case let .array(items) where Int(part).map(items.indices.contains) == true: value = items[Int(part)!]
            default: throw LayoutError("\(path): data has no value at \"\(key)\"")
            }
        }
        return value
    }

    private static func resolve(_ key: String, in scope: [String: String]) -> String {
        let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let prefix = scope[String(parts[0])] else { return key }
        return parts.count == 2 ? "\(prefix).\(parts[1])" : prefix
    }

    private static func join(_ path: String, _ key: String) -> String {
        path.isEmpty ? key : "\(path).\(key)"
    }
}
