import Foundation

public struct PackedNode: Codable, Sendable {
    public enum Failure: String, Choice, Error {
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

    public init(packing value: JSONValue) throws(LayoutError) {
        let json = value.json
        let packed = try Deflate.compress(json, dictionary: WireDictionary.v1)
        text = CompactFrame(hash: fnv1a(json), packed: packed).text
    }

    public static func admitting(_ value: JSONValue) throws(LayoutError) -> (drawing: Self, requirement: Layout.Requirement) {
        let decoded = try value.decodedAvatar()
        return (try Self(packing: value), decoded.requirement)
    }

    public var compressedBytes: Int? {
        text.flatMap(CompactFrame.init)?.packed.count
    }

    public func node() throws(Failure) -> Node {
        guard let text, text.utf8.count <= Layout.maximumBytes * 2, let frame = CompactFrame(text) else { throw .frame }
        guard let json = Deflate.decompress(frame.packed, limit: Layout.maximumBytes, dictionary: WireDictionary.v1) else { throw .inflate }
        guard fnv1a(json) == frame.hash else { throw .frame }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json))
            return try value.avatarNode()
        } catch { throw .decode }
    }
}

extension PreparedNode {
    public func admittingAvatar() throws(LayoutError) -> (drawing: PackedNode, requirement: Layout.Requirement) {
        do { return try PackedNode.admitting(value) }
        catch { throw parts.locating(error) }
    }
}

extension JSONValue {
    public func avatarNode() throws(LayoutError) -> Node { try decodedAvatar().node }

    fileprivate func decodedAvatar() throws(LayoutError) -> (node: Node, requirement: Layout.Requirement) {
        try refusingAvatarData(at: "sender.avatar")
        let decoded: (value: AvatarContent, log: FeatureLog)
        do { decoded = try decodeLayout(AvatarContent.self, json: JSONValue.object(["sender": .object(["avatar": self])]).json) }
        catch {
            if error.description.hasPrefix("sender.avatar") { throw error }
            throw LayoutError("sender.avatar: \(error)")
        }
        do { try [decoded.value.node].admit() }
        catch { throw LayoutError("sender.avatar: \(error)") }
        try decoded.value.node.admitAvatar(at: "sender.avatar")
        guard let requirement = decoded.log.requirement else { preconditionFailure("Every avatar records its required version") }
        return (decoded.value.node, requirement)
    }
}

private struct AvatarContent: Decodable {
    let node: Node

    init(from decoder: any Decoder) throws {
        let sender = try decoder.container(keyedBy: Key.self).nestedContainer(keyedBy: Key.self, forKey: Key(stringValue: "sender"))
        FeatureLog.record("notification.avatar.node", at: sender.codingPath + [Key(stringValue: "avatar")])
        node = try sender.required("avatar")
    }
}

private extension JSONValue {
    func refusingAvatarData(at path: String) throws(LayoutError) {
        switch self {
        case let .object(fields):
            if templateConstruct == .each { throw LayoutError("\(path).each: an avatar has no data; use a fixed node") }
            for key in fields.keys.sorted() { try fields[key]!.refusingAvatarData(at: "\(path).\(key)") }
        case let .array(items):
            for (index, value) in items.enumerated() { try value.refusingAvatarData(at: "\(path)[\(index)]") }
        case .string where templateConstruct == .placeholder:
            throw LayoutError("\(path): an avatar has no data; replace the placeholder with a fixed value")
        case .string, .number, .bool, .null: break
        }
    }
}

private extension Node {
    static func admitAvatars(_ nodes: [Node], at path: String) throws(LayoutError) {
        for (index, node) in nodes.enumerated() { try node.admitAvatar(at: "\(path)[\(index)]") }
    }

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
        case let .hstack(nodes, _, _): try Self.admitAvatars(nodes, at: "\(path).hstack")
        case let .vstack(nodes, _, _): try Self.admitAvatars(nodes, at: "\(path).vstack")
        case let .zstack(nodes, _): try Self.admitAvatars(nodes, at: "\(path).zstack")
        case let .concat(nodes): try Self.admitAvatars(nodes, at: "\(path).concat")
        case let .viewThatFits(nodes, _): try Self.admitAvatars(nodes, at: "\(path).viewThatFits")
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
