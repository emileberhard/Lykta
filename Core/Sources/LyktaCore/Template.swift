import Foundation

extension JSONValue {
    public func filled(with data: JSONValue) throws(LayoutError) -> JSONValue {
        var template = Template(data: data)
        var parts = try Parts(self)
        let expanded = try parts.expand(self)
        let filled: JSONValue
        do { filled = try template.fill(expanded, at: "", output: "", in: [:]) }
        catch { throw parts.locating(error) }
        if case let .object(fields) = self, fields["parts"] != nil {
            do { _ = try Layout(json: filled.json) }
            catch { throw parts.locating(template.locating(error)) }
        }
        return filled
    }

    public func value(at path: String) throws(LayoutError) -> JSONValue {
        var value = self
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            switch value {
            case let .object(fields) where fields[String(part)] != nil: value = fields[String(part)]!
            case let .array(items) where part.arrayIndex.map(items.indices.contains) == true: value = items[part.arrayIndex!]
            default: throw LayoutError("data has no value at \"\(path)\"")
            }
        }
        return value
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
        case var .array(items) where part.arrayIndex.map(items.indices.contains) == true:
            items[part.arrayIndex!] = try items[part.arrayIndex!].replacing(parts.dropFirst(), with: value, path: path)
            return .array(items)
        default:
            throw LayoutError("data has no value at \"\(path)\"")
        }
    }
}

private extension Substring {
    var arrayIndex: Int? {
        Int(self).flatMap { String($0) == self ? $0 : nil }
    }
}

private struct Template {
    let data: JSONValue
    var repeated = 0
    var bytes = 0
    private var locations: [String: String] = [:]

    init(data: JSONValue) { self.data = data }

    func locating(_ error: LayoutError) -> LayoutError {
        for path in locations.keys.sorted(by: { $0.count > $1.count }) {
            if error.description.hasPrefix(path + ":") || error.description.hasPrefix(path + ".") || error.description.hasPrefix(path + "[") {
                return LayoutError(locations[path]! + error.description.dropFirst(path.count))
            }
        }
        return error
    }

    mutating func fill(_ value: JSONValue, at path: String, output: String, in scope: [String: String]) throws(LayoutError) -> JSONValue {
        if path != output { locations[output] = path }
        switch value {
        case let .object(fields):
            guard fields["each"] == nil else { throw LayoutError("\(path): each must be an item in a list") }
            var filled: [String: JSONValue] = [:]
            for (key, value) in fields where key != "toggle" {
                try count(key.utf8.count)
                filled[key] = try fill(value, at: Self.join(path, key), output: Self.join(output, key), in: scope)
            }
            if let binding = fields["toggle"] {
                filled.merge(try bind(binding, at: path, in: scope, existing: filled)) { $1 }
            }
            if fields["button"] != nil {
                for key in ["set", "add", "now"] {
                    guard case let .object(changes) = filled[key] else { continue }
                    filled[key] = .object(try relocate(changes, of: key, at: Self.join(path, key), in: scope))
                }
            }
            return .object(filled)
        case let .array(items):
            var filled: [JSONValue] = []
            for (index, item) in items.enumerated() {
                if case let .object(fields) = item, fields["each"] != nil {
                    filled += try repeating(fields, at: "\(path)[\(index)]", output: output, offset: filled.count, in: scope)
                } else {
                    filled.append(try fill(item, at: "\(path)[\(index)]", output: "\(output)[\(filled.count)]", in: scope))
                }
            }
            return .array(filled)
        case let .string(text) where text.contains("{{"):
            return try substitute(text, at: path, in: scope)
        case let .string(text):
            try count(text.utf8.count)
            return value
        case .number, .bool, .null:
            try count(1)
            return value
        }
    }

    private mutating func count(_ size: Int) throws(LayoutError) {
        bytes += size
        guard bytes <= Layout.maximumBytes else { throw LayoutError("the filled layout is over \(Layout.maximumBytes) bytes") }
    }

    private mutating func measure(_ value: JSONValue) throws(LayoutError) {
        switch value {
        case let .object(fields):
            for (key, value) in fields {
                try count(key.utf8.count)
                try measure(value)
            }
        case let .array(items):
            for item in items { try measure(item) }
        case let .string(text):
            try count(text.utf8.count)
        case .number, .bool, .null:
            try count(1)
        }
    }

    private mutating func repeating(_ fields: [String: JSONValue], at path: String, output: String, offset: Int, in scope: [String: String]) throws(LayoutError) -> [JSONValue] {
        guard Set(fields.keys) == ["each", "as", "do"], case let .string(source) = fields["each"], case let .string(name) = fields["as"],
              let item = fields["do"] else {
            throw LayoutError(#"\#(path): expected {"each": "list.path", "as": "name", "do": item}"#)
        }
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
            throw LayoutError("\(path).as: a name starts with a letter and has only letters, digits and _")
        }
        let list = try locate(source, in: scope, for: "\(path).each")
        guard case let .array(items) = try self.value(at: list, for: "\(path).each") else {
            throw LayoutError("\(path).each: data \"\(source)\" is not a list")
        }
        repeated += items.count
        guard repeated <= Layout.maximumNodes else { throw LayoutError("each repeats more than \(Layout.maximumNodes) items") }
        var filled: [JSONValue] = []
        for index in items.indices {
            filled.append(try fill(item, at: "\(path).do", output: "\(output)[\(offset + index)]", in: scope.merging([name: "\(list).\(index)"]) { $1 }))
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
        let target = try locate(source, in: scope, for: Self.join(path, "toggle"))
        guard case let .bool(isOn) = try value(at: target, for: Self.join(path, "toggle")) else {
            throw LayoutError("\(Self.join(path, "toggle")): data \"\(target)\" must be true or false")
        }
        return ["toggle": .string(target), "isOn": .bool(isOn)]
    }

    private func relocate(_ changes: [String: JSONValue], of kind: String, at path: String,
                          in scope: [String: String]) throws(LayoutError) -> [String: JSONValue] {
        var located: [String: JSONValue] = [:]
        for (target, change) in changes.sorted(by: { $0.key < $1.key }) {
            let at = Self.join(path, target)
            var change = change
            if kind == "add", case var .object(fields) = change, case let .string(since) = fields["since"] {
                let date = try locate(since, in: scope, for: at)
                _ = try value(at: date, for: at)
                fields["since"] = .string(date)
                change = .object(fields)
            }
            let resolved = try locate(target, in: scope, for: at)
            _ = try value(at: resolved, for: at)
            guard located.updateValue(change, forKey: resolved) == nil else {
                throw LayoutError("\(at): \"\(resolved)\" is already changed by this button; change each value once")
            }
        }
        return located
    }

    private mutating func substitute(_ text: String, at path: String, in scope: [String: String]) throws(LayoutError) -> JSONValue {
        var output = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            guard let close = rest[open.upperBound...].range(of: "}}") else { throw LayoutError("\(path): unclosed {{") }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = try value(at: locate(key, in: scope, for: path), for: path)
            if output.isEmpty, open.lowerBound == rest.startIndex, close.upperBound == rest.endIndex {
                try measure(value)
                return value
            }
            let inserted = switch value {
            case let .string(string): path == "svg" || path.hasSuffix(".svg") ? Self.escaped(string) : string
            case let .number(number): number.textValue
            case let .bool(bool): String(bool)
            case .null: throw LayoutError("\(path): data \"\(key)\" is null and cannot be inserted into text")
            case .array, .object: throw LayoutError("\(path): data \"\(key)\" is not a single value and cannot be inserted into text")
            }
            try count(rest[..<open.lowerBound].utf8.count + inserted.utf8.count)
            output += rest[..<open.lowerBound]
            output += inserted
            rest = rest[close.upperBound...]
        }
        try count(rest.utf8.count)
        return .string(output + rest)
    }

    private static func escaped(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
            .replacing("\"", with: "&quot;").replacing("'", with: "&apos;")
    }

    private func value(at key: String, for path: String) throws(LayoutError) -> JSONValue {
        do {
            return try data.value(at: key)
        } catch {
            throw LayoutError("\(path): \(error)")
        }
    }

    private func locate(_ key: String, in scope: [String: String], for path: String) throws(LayoutError) -> String {
        var located = ""
        var rest = Substring(key)
        while let open = rest.firstIndex(of: "[") {
            guard let close = rest[open...].firstIndex(of: "]"), !rest[rest.index(after: open)..<close].contains("[") else {
                throw LayoutError("\(path): \"\(key)\" has an unclosed [")
            }
            let inner = String(rest[rest.index(after: open)..<close])
            let segment = switch try value(at: Self.resolve(inner, in: scope), for: path) {
            case let .number(index) where index >= 0 && index == index.rounded(): index.textValue
            case let .string(name) where !name.isEmpty && !name.contains(where: { ".[]".contains($0) }): name
            default: throw LayoutError("\(path): data \"\(inner)\" must be an index or a key to look up \"\(key)\"")
            }
            located += rest[..<open] + "." + segment
            rest = rest[rest.index(after: close)...]
        }
        return Self.resolve(located + rest, in: scope)
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
