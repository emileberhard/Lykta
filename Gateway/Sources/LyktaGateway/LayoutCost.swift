import LyktaCore

enum LayoutCost {
    private struct Part {
        let path: String
        let value: JSONValue
        let bytes: Int
    }

    private static let probes = 48

    static func describe(_ layout: JSONValue) throws -> String {
        let baseline = try layout.compressedByteCount
        let groups = Dictionary(grouping: parts(layout, path: "layout"), by: \.value).values.sorted { (left: [Part], right: [Part]) -> Bool in
            let a = left[0], b = right[0]
            return a.bytes == b.bytes ? a.path < b.path : a.bytes > b.bytes
        }
        var costs: [(name: String, saving: Int)] = []
        for group in groups.prefix(probes) {
            let saving = baseline - (try removing(group[0].value, from: layout)?.compressedByteCount ?? 0)
            let name = String(group[0].path.prefix(160)) + (group.count > 1 ? " with \(group.count - 1) identical copies" : "")
            if saving > 0 { costs.append((name, saving)) }
        }
        costs.sort { $0.saving == $1.saving ? $0.name < $1.name : $0.saving > $1.saving }
        guard !costs.isEmpty else { return "Shorten text or simplify distinct detail; repeated parts cost little." }
        let entries = costs.prefix(5).map { "\($0.name) ~\($0.saving)" }.joined(separator: ", ")
        return "Estimated compressed bytes saved by removing each part: \(entries). "
            + "The estimates overlap, so they do not add up. Simplify detail at those paths."
    }

    private static func parts(_ value: JSONValue, path: String) -> [Part] {
        let children: [Part] = switch value {
        case let .object(fields): fields.sorted { $0.key < $1.key }.flatMap { parts($0.value, path: "\(path).\($0.key)") }
        case let .array(values): values.enumerated().flatMap { parts($0.element, path: "\(path)[\($0.offset)]") }
        default: []
        }
        if !children.isEmpty { return children }
        let bytes = value.json.count
        return path != "layout" && bytes >= 128 ? [Part(path: path, value: value, bytes: bytes)] : []
    }

    private static func removing(_ part: JSONValue, from value: JSONValue) -> JSONValue? {
        if value == part { return nil }
        return switch value {
        case let .object(fields): .object(fields.compactMapValues { removing(part, from: $0) })
        case let .array(values): .array(values.compactMap { removing(part, from: $0) })
        default: value
        }
    }
}
