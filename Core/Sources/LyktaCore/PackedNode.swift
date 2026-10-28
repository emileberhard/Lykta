import Foundation

public struct PackedNode: Codable, Sendable {
    public enum Failure: String, Choice, Encodable, Error {
        case frame, inflate, decode, deadline, render
    }

    private let text: String?

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        if case let .string(text) = value { self.text = text }
        else { text = nil }
    }

    public func encode(to encoder: any Encoder) throws {
        guard let text else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "a packed node must be a frame string"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    private init(text: String) { self.text = text }

    public static func admitting(_ value: JSONValue) throws(LayoutError) -> (drawing: Self, requirement: Layout.Requirement) {
        try value.refusingAvatarData(at: "sender.avatar")
        let decoded = try avatarNode(value.json)
        let packed = try Deflate.compress(value.json, dictionary: WireDictionary.v1)
        return (Self(text: CompactFrame(hash: fnv1a(value.json), packed: packed).text), decoded.requirement)
    }

    public var fingerprint: String? {
        text.flatMap(CompactFrame.init).map { String($0.hash, radix: 16) }
    }

    public var compressedBytes: Int? {
        text.flatMap(CompactFrame.init)?.packed.count
    }

    public func node(limit: Int) throws(Failure) -> Node {
        guard let text, text.utf8.count <= Layout.maximumBytes * 2, let frame = CompactFrame(text) else { throw .frame }
        guard (0...Layout.maximumBytes).contains(limit),
              let json = Deflate.decompress(frame.packed, limit: limit, dictionary: WireDictionary.v1) else { throw .inflate }
        guard fnv1a(json) == frame.hash else { throw .frame }
        do { return try Self.avatarNode(json).node }
        catch { throw .decode }
    }

    private static func avatarNode(_ json: [UInt8]) throws(LayoutError) -> (node: Node, requirement: Layout.Requirement) {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: Data(json)) }
        catch let error as DecodingError { throw LayoutError(error) }
        catch { throw LayoutError("\(error)") }
        let decoded: (value: AvatarContent, log: FeatureLog)
        do { decoded = try decodeLayout(AvatarContent.self, json: JSONValue.object(["lockScreen": value]).json) }
        catch {
            if let origin = error.origin(in: ["lockScreen": "sender.avatar"]) { throw LayoutError(origin.source + origin.rest) }
            throw error
        }
        try [decoded.value.node].admit()
        try decoded.value.node.admitAvatar(at: "sender.avatar")
        guard let requirement = decoded.log.requirement else { preconditionFailure("Every avatar records its required version") }
        return (decoded.value.node, requirement)
    }
}

private struct AvatarContent: Decodable {
    let node: Node

    init(from decoder: any Decoder) throws {
        FeatureLog.record("notification.avatar.node", at: [Key(stringValue: "sender"), Key(stringValue: "avatar")])
        node = try decoder.container(keyedBy: Key.self).required("lockScreen")
    }
}

private extension JSONValue {
    func refusingAvatarData(at path: String) throws(LayoutError) {
        switch self {
        case let .object(fields):
            if fields["each"] != nil { throw LayoutError("\(path).each: an avatar has no data; use a fixed node") }
            for key in fields.keys.sorted() { try fields[key]!.refusingAvatarData(at: "\(path).\(key)") }
        case let .array(items):
            for (index, value) in items.enumerated() { try value.refusingAvatarData(at: "\(path)[\(index)]") }
        case let .string(text) where text.contains("{{"):
            throw LayoutError("\(path): an avatar has no data; replace the placeholder with a fixed value")
        case .string, .number, .bool, .null: break
        }
    }
}

private extension Node {
    func admitAvatar(at path: String) throws(LayoutError) {
        switch content {
        case .link, .button, .toggle:
            throw LayoutError("\(path): controls and links need interaction, and an avatar is drawn once; use a fixed node")
        case .timer, .progress(.interval, _):
            throw LayoutError("\(path): timers and interval progress change with time, and an avatar is drawn once; use a fixed value")
        case .date(_, .relative), .date(_, .offset), .date(_, .timer):
            throw LayoutError("\(path): relative dates change with time, and an avatar is drawn once; use a fixed date or time")
        case .conditional(.environment, _, _):
            throw LayoutError("\(path).if: environment conditions change after arrival, and an avatar is drawn once; use a fixed condition")
        case let .hstack(nodes, _, _), let .vstack(nodes, _, _), let .zstack(nodes, _), let .concat(nodes), let .viewThatFits(nodes, _):
            let kind: String = switch content {
            case .hstack: "hstack"
            case .vstack: "vstack"
            case .zstack: "zstack"
            case .concat: "concat"
            default: "viewThatFits"
            }
            for (index, node) in nodes.enumerated() { try node.admitAvatar(at: "\(path).\(kind)[\(index)]") }
        case let .grid(rows, _, _, _):
            for (row, nodes) in rows.enumerated() {
                for (index, node) in nodes.enumerated() { try node.admitAvatar(at: "\(path).grid[\(row)][\(index)]") }
            }
        case let .gauge(gauge):
            for (key, node) in [("label", gauge.label), ("currentValueLabel", gauge.currentValueLabel),
                                ("minimumValueLabel", gauge.minimumValueLabel), ("maximumValueLabel", gauge.maximumValueLabel)] {
                try node?.admitAvatar(at: "\(path).\(key)")
            }
        case let .conditional(.value, then, otherwise):
            try then.admitAvatar(at: "\(path).then")
            try otherwise?.admitAvatar(at: "\(path).else")
        case .text, .symbol, .shape, .svg, .spacer, .divider, .progress(.value, _), .date(_, .date), .date(_, .time), .chart, .accessoryBackground: break
        }
        for (index, modifier) in modifiers.enumerated() {
            switch modifier {
            case let .overlay(node): try node.admitAvatar(at: "\(path).modifiers[\(index)].overlay")
            case .padding, .frame, .fixedSize, .layoutPriority, .offset, .rotation, .scale, .opacity, .foreground, .background,
                 .tint, .clip, .shadow, .font, .fontWeight, .fontDesign, .fontWidth, .bold, .italic, .underline, .strikethrough,
                 .monospacedDigit, .tracking, .lineLimit, .minimumScaleFactor, .multilineTextAlignment, .truncationMode,
                 .textCase, .contentTransition, .transition, .animation, .id, .blur, .grayscale, .saturation, .brightness,
                 .symbolRenderingMode, .imageScale, .accessibilityLabel, .privacySensitive: break
            }
        }
    }
}
