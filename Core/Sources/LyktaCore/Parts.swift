extension JSONValue {
    public func expandingParts(for surface: Surface) throws(LayoutError) -> JSONValue {
        try PreparedParts(self, saved: [:], for: surface).value
    }
}

public typealias SavedParts = [Name: JSONValue]

public struct PreparedParts: Sendable {
    public let value: JSONValue
    let parts: Parts
    let surface: Surface

    public init(_ value: JSONValue, saved: SavedParts, for surface: Surface) throws(LayoutError) {
        var parts = try Parts(value, saved: saved)
        self.value = try parts.expand(value, for: surface)
        self.parts = parts
        self.surface = surface
    }
}

struct Parts: Sendable {
    fileprivate static let nodeLists = ["hstack", "vstack", "zstack", "concat", "viewThatFits"]
    fileprivate static let nodeChildren = ["then", "else", "label", "currentValueLabel", "minimumValueLabel", "maximumValueLabel"]
    private let definitions: [String: JSONValue]?
    private let saved: SavedParts
    private var used: Set<String> = []
    private var nodes = 0
    private var origins: [String: String] = [:]
    private var savedUses: [String: String] = [:]

    init(_ value: JSONValue, saved: SavedParts) throws(LayoutError) {
        self.saved = saved
        guard case let .object(fields) = value, let parts = fields["parts"] else {
            definitions = nil
            return
        }
        guard case let .object(definitions) = parts else { throw LayoutError("parts: expected an object of named nodes") }
        self.definitions = definitions
    }

    mutating func expand(_ value: JSONValue, for surface: Surface) throws(LayoutError) -> JSONValue {
        guard case var .object(fields) = value else { return value }
        fields.removeValue(forKey: "parts")
        for key in fields.keys.sorted() {
            if key == "expanded", case var .object(regions) = fields[key] {
                for region in regions.keys.sorted() {
                    regions[region] = try node(regions[region]!, at: "expanded.\(region)", source: "expanded.\(region)", stack: [])
                }
                fields[key] = .object(regions)
            } else if surface.nodeKeys.contains(key) {
                fields[key] = try node(fields[key]!, at: key, source: key, stack: [])
            }
        }
        if let unused = (definitions ?? [:]).keys.sorted().first(where: { !used.contains($0) }) {
            throw LayoutError("parts.\(unused): part is not used")
        }
        return .object(fields)
    }

    var hasDefinitions: Bool { definitions != nil || !saved.isEmpty }

    func locating(_ error: LayoutError) -> LayoutError {
        guard let (source, path, rest) = error.origin(in: origins) else { return error }
        let isSaved = savedUses.contains { site, root in
            (path == site || path.hasPrefix(site + ".") || path.hasPrefix(site + "["))
                && (source == root || source.hasPrefix(root + ".") || source.hasPrefix(root + "["))
        }
        return LayoutError(source + rest + " (\(isSaved ? "saved part, " : "")used at \(path))")
    }

    mutating func expandNode(_ value: JSONValue) throws(LayoutError) -> JSONValue {
        try node(value, at: "part", source: "part", stack: [])
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
            guard let part = definitions?[name] ?? Name(rawValue: name).flatMap({ saved[$0] }) else {
                throw LayoutError(undefinedPart: name, at: source, defined: Array((definitions ?? [:]).keys))
            }
            if let start = stack.firstIndex(of: name) {
                throw LayoutError("\(source): part cycle: \((Array(stack[start...]) + [name]).joined(separator: " -> "))")
            }
            if let modifiers = fields["modifiers"] {
                guard case let .array(added) = modifiers else { throw LayoutError("\(source).modifiers: expected an array") }
                uses.append((source, added, stack.count))
            }
            if definitions?[name] == nil { savedUses[path] = "parts.\(name)" }
            used.insert(name)
            stack.append(name)
            value = part
            source = "parts.\(name)"
        }
        var expanded: JSONValue
        if case let .object(fields) = value, fields["each"] != nil, fields["do"] != nil {
            if source != path { origins[path] = source }
            expanded = try element(value, as: .node, at: path, source: source, stack: stack)
        } else {
            expanded = try copy(value, at: path, source: source, stack: stack)
        }
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
                combined.append(try element(modifier, as: .modifier, at: target, source: authored, stack: Array(stack.prefix(use.depth))))
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
        guard definitions == nil && saved.isEmpty || nodes <= Layout.maximumNodes else {
            throw LayoutError("parts expand to more than \(Layout.maximumNodes) nodes")
        }
        guard case var .object(fields) = value else { return value }
        for key in fields.keys.sorted() {
            let at = "\(path).\(key)"
            let authored = "\(source).\(key)"
            if Self.nodeLists.contains(key) {
                fields[key] = try list(fields[key]!, of: .node, at: at, source: authored, stack: stack)
            } else if key == "grid" {
                fields[key] = try list(fields[key]!, of: .row, at: at, source: authored, stack: stack)
            } else if Self.nodeChildren.contains(key) {
                fields[key] = try node(fields[key]!, at: at, source: authored, stack: stack)
            } else if key == "modifiers" {
                fields[key] = try list(fields[key]!, of: .modifier, at: at, source: authored, stack: stack)
            }
        }
        return .object(fields)
    }

    private enum Element {
        case node, row, modifier
    }

    private mutating func list(_ value: JSONValue, of kind: Element, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        guard case let .array(items) = value else { return value }
        var result: [JSONValue] = []
        for (index, item) in items.enumerated() {
            result.append(try element(item, as: kind, at: "\(path)[\(index)]", source: "\(source)[\(index)]", stack: stack))
        }
        return .array(result)
    }

    private mutating func element(_ value: JSONValue, as kind: Element, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        if case var .object(fields) = value, fields["each"] != nil, let body = fields["do"] {
            fields["do"] = try element(body, as: kind, at: "\(path).do", source: "\(source).do", stack: stack)
            return .object(fields)
        }
        return switch kind {
        case .node: try node(value, at: path, source: source, stack: stack)
        case .row: try list(value, of: .node, at: path, source: source, stack: stack)
        case .modifier: try modifier(value, at: path, source: source, stack: stack)
        }
    }

    private mutating func modifier(_ value: JSONValue, at path: String, source: String, stack: [String]) throws(LayoutError) -> JSONValue {
        guard case var .object(fields) = value, let overlay = fields["overlay"] else { return value }
        fields["overlay"] = try node(overlay, at: "\(path).overlay", source: "\(source).overlay", stack: stack)
        return .object(fields)
    }
}

extension JSONValue {
    public func savedPartReferences(for surface: Surface) throws(LayoutError) -> Set<Name> {
        let parts = try Parts(self, saved: [:])
        return try parts.references(in: roots(for: surface))
    }

    public func savedPartReferences() throws(LayoutError) -> Set<Name> {
        try Parts.references(in: [self])
    }

    public func expandingPart(saved: SavedParts) throws(LayoutError) -> JSONValue {
        guard json.count <= Layout.maximumBytes else {
            throw LayoutError("part is \(json.count) bytes; the limit is \(Layout.maximumBytes)")
        }
        if case let .object(fields) = self, fields["parts"] != nil {
            throw LayoutError("parts: a saved part cannot define parts; save each part separately")
        }
        var parts = try Parts(.object([:]), saved: saved)
        let expanded = try parts.expandNode(self)
        try expanded.admitPartStructure()
        return expanded
    }

    private func roots(for surface: Surface) -> [JSONValue] {
        guard case let .object(fields) = self else { return [] }
        var roots = surface.nodeKeys.sorted().compactMap { fields[$0] }
        if surface == .activity, case let .object(regions) = fields["expanded"] {
            roots += regions.keys.sorted().compactMap { regions[$0] }
        }
        return roots
    }

    private func admitPartStructure() throws(LayoutError) {
        guard json.count <= Layout.maximumBytes else {
            throw LayoutError("part is \(json.count) bytes; the limit is \(Layout.maximumBytes)")
        }
        var nodes = 0
        var modifiers = 0
        try walkNodes { (value, depth) throws(LayoutError) in
            switch value {
            case .object, .string, .number: break
            default: throw LayoutError("part: expected a node object or text shorthand")
            }
            nodes += 1
            if case let .object(fields) = value, let authored = fields["modifiers"] {
                guard case let .array(items) = authored else { throw LayoutError("part.modifiers: expected an array") }
                modifiers += items.count
            }
            guard depth <= Layout.maximumDepth else { throw LayoutError("nodes nest deeper than \(Layout.maximumDepth) levels") }
            guard nodes <= Layout.maximumNodes else { throw LayoutError("layout has more than \(Layout.maximumNodes) nodes") }
            guard modifiers <= Layout.maximumModifiers else { throw LayoutError("layout has more than \(Layout.maximumModifiers) modifiers") }
        }
    }

    fileprivate func walkNodes(_ visit: (JSONValue, Int) throws(LayoutError) -> Void) throws(LayoutError) {
        var pending: [(JSONValue, Int)] = [(self, 1)]
        while let (value, depth) = pending.popLast() {
            guard case let .object(fields) = value else {
                try visit(value, depth)
                continue
            }
            if fields["each"] != nil, let body = fields["do"] {
                pending.append((body, depth))
                continue
            }
            try visit(value, depth)
            for key in Parts.nodeLists {
                if case let .array(items) = fields[key] { pending += items.map { ($0, depth + 1) } }
            }
            if case let .array(rows) = fields["grid"] {
                for row in rows {
                    if case let .array(items) = row { pending += items.map { ($0, depth + 1) } }
                    else if case let .object(repetition) = row, case let .array(items) = repetition["do"] {
                        pending += items.map { ($0, depth + 1) }
                    }
                }
            }
            for key in Parts.nodeChildren {
                if let child = fields[key], child != .null { pending.append((child, depth + 1)) }
            }
            if case let .array(modifiers) = fields["modifiers"] {
                for modifier in modifiers {
                    var modifier = modifier
                    while case let .object(fields) = modifier, fields["each"] != nil, let body = fields["do"] { modifier = body }
                    if case let .object(fields) = modifier, let overlay = fields["overlay"] { pending.append((overlay, depth + 1)) }
                }
            }
        }
    }
}

extension Parts {
    func references(in roots: [JSONValue]) throws(LayoutError) -> Set<Name> {
        try Self.references(in: roots + Array((definitions ?? [:]).values)).filter { definitions?[$0.rawValue] == nil }
    }

    static func references(in roots: [JSONValue]) throws(LayoutError) -> Set<Name> {
        var names: Set<Name> = []
        for root in roots {
            try root.walkNodes { value, _ in
                if case let .object(fields) = value, case let .string(text) = fields["use"], let name = Name(rawValue: text) {
                    names.insert(name)
                }
            }
        }
        return names
    }
}
