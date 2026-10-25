extension JSONValue {
    public func expandingParts() throws(LayoutError) -> JSONValue {
        var parts = try Parts(self)
        return try parts.expand(self)
    }
}

struct Parts {
    private let definitions: [String: JSONValue]
    private var used: Set<String> = []
    private var nodes = 0
    private var origins: [String: String] = [:]

    init(_ value: JSONValue) throws(LayoutError) {
        guard case let .object(fields) = value, let parts = fields["parts"] else {
            definitions = [:]
            return
        }
        guard case let .object(definitions) = parts else { throw LayoutError("parts: expected an object of named nodes") }
        self.definitions = definitions
    }

    mutating func expand(_ value: JSONValue) throws(LayoutError) -> JSONValue {
        guard case var .object(fields) = value, fields.removeValue(forKey: "parts") != nil else { return value }
        for key in fields.keys.sorted() {
            if key == "expanded", case var .object(regions) = fields[key] {
                for region in regions.keys.sorted() {
                    regions[region] = try node(regions[region]!, at: "expanded.\(region)", source: "expanded.\(region)", stack: [])
                }
                fields[key] = .object(regions)
            } else if ["lockScreen", "compactLeading", "compactTrailing", "minimal", "small"].contains(key) {
                fields[key] = try node(fields[key]!, at: key, source: key, stack: [])
            }
        }
        if let unused = definitions.keys.sorted().first(where: { !used.contains($0) }) {
            throw LayoutError("parts.\(unused): part is not used")
        }
        return .object(fields)
    }

    func locating(_ error: LayoutError) -> LayoutError {
        for path in origins.keys.sorted(by: { $0.count > $1.count }) {
            if error.description.hasPrefix(path + ":") || error.description.hasPrefix(path + ".") || error.description.hasPrefix(path + "[") {
                return LayoutError(origins[path]! + error.description.dropFirst(path.count) + " (used at \(path))")
            }
        }
        return error
    }

    private mutating func node(_ value: JSONValue, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        var value = value
        var source = source
        var stack = stack
        var uses: [(source: String, modifiers: [JSONValue], depth: Int)] = []
        while case let .object(fields) = value, let use = fields["use"] {
            guard Set(fields.keys).isSubset(of: ["use", "modifiers"]), case let .string(name) = use else {
                throw LayoutError("\(source): expected {\"use\": \"name\"} with optional modifiers")
            }
            guard let part = definitions[name] else {
                throw LayoutError("\(source): unknown part \"\(name)\"; defined parts: \(definitions.keys.sorted().joined(separator: ", "))")
            }
            if let start = stack.firstIndex(of: name) {
                throw LayoutError("\(source): part cycle: \((Array(stack[start...]) + [name]).joined(separator: " -> "))")
            }
            if let modifiers = fields["modifiers"] {
                guard case let .array(added) = modifiers else { throw LayoutError("\(source).modifiers: expected an array") }
                uses.append((source, added, stack.count))
            }
            used.insert(name)
            stack.append(name)
            value = part
            source = "parts.\(name)"
        }
        var expanded = try copy(value, at: path, source: source, stack: stack)
        for use in uses.reversed() {
            var result: [String: JSONValue]
            switch expanded {
            case let .object(fields): result = fields
            case .string, .number: result = ["text": expanded]
            default: throw LayoutError("\(source): expected a node")
            }
            var combined: [JSONValue]
            if let modifiers = result["modifiers"] {
                guard case let .array(items) = modifiers else { throw LayoutError("\(source).modifiers: expected an array") }
                combined = items
            } else { combined = [] }
            let offset = combined.count
            for (index, modifier) in use.modifiers.enumerated() {
                let target = "\(path).modifiers[\(offset + index)]"
                let authored = "\(use.source).modifiers[\(index)]"
                origins[target] = authored
                combined.append(try self.modifier(modifier, at: target, source: authored, stack: Array(stack.prefix(use.depth))))
            }
            result["modifiers"] = .array(combined)
            expanded = .object(result)
        }
        return expanded
    }

    private mutating func copy(_ value: JSONValue, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        if source != path { origins[path] = source }
        if case .null = value { return value }
        nodes += 1
        guard nodes <= Layout.maximumNodes else { throw LayoutError("parts expand to more than \(Layout.maximumNodes) nodes") }
        if case let .object(fields) = value, fields["each"] != nil, let body = fields["do"] {
            var fields = fields
            fields["do"] = try node(body, at: "\(path).do", source: "\(source).do", stack: stack)
            return .object(fields)
        }
        guard case var .object(fields) = value else { return value }
        for key in fields.keys.sorted() {
            let at = "\(path).\(key)"
            let authored = "\(source).\(key)"
            if ["hstack", "vstack", "zstack", "concat", "viewThatFits", "grid"].contains(key) {
                fields[key] = try list(fields[key]!, at: at, source: authored, stack: stack)
            } else if ["then", "else", "label", "currentValueLabel", "minimumValueLabel", "maximumValueLabel"].contains(key) {
                fields[key] = try node(fields[key]!, at: at, source: authored, stack: stack)
            } else if key == "modifiers", case let .array(items) = fields[key] {
                var modifiers: [JSONValue] = []
                for (index, item) in items.enumerated() {
                    modifiers.append(try modifier(item, at: "\(at)[\(index)]", source: "\(authored)[\(index)]", stack: stack))
                }
                fields[key] = .array(modifiers)
            }
        }
        return .object(fields)
    }

    private mutating func list(_ value: JSONValue, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        guard case let .array(items) = value else { return value }
        var result: [JSONValue] = []
        for (index, item) in items.enumerated() {
            let at = "\(path)[\(index)]"
            let authored = "\(source)[\(index)]"
            if case .array = item { result.append(try list(item, at: at, source: authored, stack: stack)) }
            else { result.append(try node(item, at: at, source: authored, stack: stack)) }
        }
        return .array(result)
    }

    private mutating func modifier(_ value: JSONValue, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        guard case var .object(fields) = value, let overlay = fields["overlay"] else { return value }
        fields["overlay"] = try node(overlay, at: "\(path).overlay", source: "\(source).overlay", stack: stack)
        return .object(fields)
    }
}
