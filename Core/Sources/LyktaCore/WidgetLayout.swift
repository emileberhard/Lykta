import Foundation

public struct WidgetLayout: Decodable, Sendable {
    public enum Family: String, Choice, Encodable {
        case systemSmall, systemMedium, systemLarge, accessoryCircular, accessoryRectangular, accessoryInline

        public var isAccessory: Bool {
            switch self {
            case .systemSmall, .systemMedium, .systemLarge: false
            case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
            }
        }
    }

    public enum Background: Sendable {
        case paint(Paint)
        case node(Node)
    }

    static let nodeKeys = Set(Family.allCases.map(\.rawValue)).union(["background"])

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
        for family in Family.allCases {
            presentations[family] = try fields.optional(family.rawValue)
        }
        guard !presentations.isEmpty else {
            throw fields.invalid("a widget needs at least one of \(Family.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard presentations[.accessoryInline]?.fitsOneLine != false else {
            throw fields.invalid("takes only text, concat, symbol, date and timer nodes with text modifiers and privacySensitive, or an if choosing between them; "
                                 + "a concat with both a symbol and a relative date or timer holds only the symbol and then that one part",
                                 at: Family.accessoryInline.rawValue)
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
