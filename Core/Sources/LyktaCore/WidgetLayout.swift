import Foundation

public struct WidgetLayout: Decodable, Sendable {
    public enum Family: String, Choice, Encodable {
        case systemSmall, systemMedium, systemLarge, accessoryCircular, accessoryRectangular, accessoryInline
    }

    public enum Background: Sendable {
        case paint(Paint)
        case node(Node)
    }

    static let drawn: [Family] = [.systemSmall]
    static let nodeKeys = Set(drawn.map(\.rawValue)).union(["background"])

    public let presentations: [Family: Node]
    public let background: Background?
    public let link: URL?
    public private(set) var requirement: Layout.Requirement?
    private(set) var features: [String] = []

    public init(json: [UInt8]) throws(LayoutError) {
        let decoded = try decodeLayout(WidgetLayout.self, json: json)
        self = decoded.value
        try roots.admit()
        requirement = decoded.log.requirement
        features = decoded.log.features
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(Self.nodeKeys.union(["link"]))
        fields.recordKeys(in: "widget")
        var presentations: [Family: Node] = [:]
        for family in Self.drawn {
            presentations[family] = try fields.optional(family.rawValue)
        }
        guard !presentations.isEmpty else {
            throw fields.invalid("a widget needs at least one of \(Self.drawn.map(\.rawValue).joined(separator: ", "))")
        }
        self.presentations = presentations
        background = try Self.background(fields)
        link = try fields.link("link")
    }

    private var roots: [Node] {
        let background: [Node] = if case let .node(node) = background { [node] } else { [] }
        return Family.allCases.compactMap { presentations[$0] } + background
    }

    private static func background(_ fields: Fields) throws -> Background? {
        guard let value: JSONValue = try fields.optional("background") else { return nil }
        if case let .object(object) = value, object.keys.contains(where: { Node.Content.fields[$0] != nil }) {
            return .node(try fields.required("background"))
        }
        return .paint(try fields.required("background"))
    }
}
