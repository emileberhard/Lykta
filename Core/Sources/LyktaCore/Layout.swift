import Foundation

public struct Layout: Decodable, Sendable {
    public static let maximumBytes = 32_768
    public static let maximumNodes = 256
    public static let maximumDepth = 16
    public static let maximumModifiers = 512

    public struct Expanded: Decodable, Sendable {
        public let leading: Node?
        public let trailing: Node?
        public let center: Node?
        public let bottom: Node?

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            try fields.allowOnly(["leading", "trailing", "center", "bottom"])
            leading = try fields.optional("leading")
            trailing = try fields.optional("trailing")
            center = try fields.optional("center")
            bottom = try fields.optional("bottom")
        }
    }

    public let lockScreen: Node
    public let compactLeading: Node
    public let compactTrailing: Node
    public let minimal: Node
    public let expanded: Expanded?
    public let small: Node?
    public let background: ColorValue?
    public let keyline: ColorValue?
    public let link: URL?

    public init(json: [UInt8]) throws(LayoutError) {
        guard json.count <= Self.maximumBytes else {
            throw LayoutError("layout is \(json.count) bytes; the limit is \(Self.maximumBytes)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.date)
        do {
            self = try decoder.decode(Layout.self, from: Data(json))
        } catch let error as DecodingError {
            throw LayoutError(error)
        } catch {
            throw LayoutError("\(error)")
        }
        var budget = (nodes: 0, modifiers: 0)
        for root in roots { try Self.admit(root, depth: 1, budget: &budget) }
    }

    public var buttons: Set<String> {
        Set(roots.flatMap(\.descendants).compactMap { if case let .button(name, _, _) = $0.content { name } else { nil } })
    }

    public var toggles: [String: Bool] {
        Dictionary(roots.flatMap(\.descendants).compactMap { if case let .toggle(path, isOn, _, _) = $0.content { (path, isOn) } else { nil } }) { $1 }
    }

    private var roots: [Node] {
        [lockScreen, compactLeading, compactTrailing, minimal, small, expanded?.leading, expanded?.trailing, expanded?.center, expanded?.bottom]
            .compactMap(\.self)
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(["lockScreen", "compactLeading", "compactTrailing", "minimal", "expanded", "small",
                              "background", "keyline", "link"])
        lockScreen = try fields.required("lockScreen")
        compactLeading = try fields.required("compactLeading")
        compactTrailing = try fields.required("compactTrailing")
        minimal = try fields.required("minimal")
        expanded = try fields.optional("expanded")
        small = try fields.optional("small")
        background = try fields.optional("background")
        keyline = try fields.optional("keyline")
        link = try fields.link("link")
    }

    private static func admit(_ node: Node, depth: Int, budget: inout (nodes: Int, modifiers: Int)) throws(LayoutError) {
        budget.nodes += 1
        budget.modifiers += node.modifiers.count
        guard depth <= maximumDepth else { throw LayoutError("nodes nest deeper than \(maximumDepth) levels") }
        guard budget.nodes <= maximumNodes else { throw LayoutError("layout has more than \(maximumNodes) nodes") }
        guard budget.modifiers <= maximumModifiers else { throw LayoutError("layout has more than \(maximumModifiers) modifiers") }
        for child in node.children { try admit(child, depth: depth + 1, budget: &budget) }
    }

    private static func date(_ decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSince1970: seconds) }
        let text = try container.decode(String.self)
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected an ISO 8601 date or Unix seconds")
    }
}

public struct Node: Decodable, Sendable {
    public let content: Content
    public let modifiers: [Modifier]

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let text = (try? container.decode(String.self)) ?? (try? container.decode(Double.self))?.textValue {
            content = .text(text)
            modifiers = []
            return
        }
        let fields = try decoder.container(keyedBy: Key.self)
        guard fields.codingPath.count < 4 * Layout.maximumDepth else { throw fields.invalid("nests too deeply") }
        let kinds = fields.allKeys.map(\.stringValue).filter { Content.fields[$0] != nil }
        guard kinds.count == 1, let kind = kinds.first, let allowed = Content.fields[kind] else {
            throw fields.invalid("a node is a string or an object with one of \(Content.fields.keys.sorted().joined(separator: ", "))")
        }
        try fields.allowOnly(allowed.union([kind, "modifiers"]))
        modifiers = try fields.optional("modifiers") ?? []
        content = try Content(kind, fields)
    }

    var isInline: Bool {
        switch content {
        case .text, .symbol, .date, .timer: modifiers.allSatisfy(\.isTextModifier)
        default: false
        }
    }

    var children: [Node] {
        content.children + modifiers.compactMap { if case let .overlay(node) = $0 { node } else { nil } }
    }

    var descendants: [Node] {
        [self] + children.flatMap(\.descendants)
    }

    var isControl: Bool {
        switch content {
        case .link, .button, .toggle: true
        default: false
        }
    }
}

extension Node {
    public indirect enum Content: Sendable {
        case text(String)
        case symbol(String, value: Double?)
        case timer(ClosedRange<Date>, countsDown: Bool, pausedAt: Date?, showsHours: Bool)
        case date(Date, style: DateStyle)
        case concat([Node])
        case shape(Shape)
        case svg(Drawing)
        case hstack([Node], alignment: VerticalAlignment, spacing: Double?)
        case vstack([Node], alignment: HorizontalAlignment, spacing: Double?)
        case zstack([Node], alignment: Alignment)
        case spacer(minLength: Double?)
        case divider
        case progress(Progress, style: ProgressStyle)
        case gauge(Gauge)
        case viewThatFits([Node], axis: Axis?)
        case conditional(Condition, then: Node, else: Node?)
        case link(URL, label: Node)
        case button(String, label: Node, style: ButtonStyle)
        case toggle(String, isOn: Bool, label: Node, style: ToggleStyle)
        case grid([[Node]], alignment: Alignment, horizontalSpacing: Double?, verticalSpacing: Double?)
        case chart(Chart)

        public enum DateStyle: String, Choice { case time, date, relative, offset, timer }
        public enum ProgressStyle: String, Choice { case linear, circular }
        public enum Axis: String, Choice { case horizontal, vertical }
        public enum ButtonStyle: String, Choice { case automatic, plain, bordered, borderedProminent }
        public enum ToggleStyle: String, Choice { case `switch`, button, checkbox }
        public enum HorizontalAlignment: String, Choice { case leading, center, trailing }
        public enum VerticalAlignment: String, Choice { case top, center, bottom, firstTextBaseline, lastTextBaseline }
        public enum Alignment: String, Choice {
            case center, leading, trailing, top, bottom, topLeading, topTrailing, bottomLeading, bottomTrailing
        }

        public enum Condition: Decodable, Sendable {
            public enum Environment: String, Choice { case stale, dark, luminanceReduced, fullscreen, limitedWidth }

            case environment(Environment)
            case value(Bool)

            public init(from decoder: any Decoder) throws {
                let container = try decoder.singleValueContainer()
                self = if let value = try? container.decode(Bool.self) { .value(value) } else { .environment(try container.decode(Environment.self)) }
            }
        }

        public enum Progress: Sendable {
            case value(Double)
            case interval(ClosedRange<Date>, countsDown: Bool, pausedAt: Date?)
        }

        public struct Shape: Sendable {
            public enum Kind: String, Choice { case rectangle, roundedRectangle, circle, ellipse, capsule, containerRelativeShape }
            public enum LineCap: String, Choice { case butt, round, square }

            public let kind: Kind
            public let cornerRadius: Double
            public let fill: Paint?
            public let stroke: Paint?
            public let lineWidth: Double
            public let lineCap: LineCap
            public let dash: [Double]
            public let trim: ClosedRange<Double>
        }

        public struct Gauge: Sendable {
            public enum Style: String, Choice { case circular, circularCapacity, linear, linearCapacity }

            public let value: Double
            public let range: ClosedRange<Double>
            public let style: Style
            public let label: Node?
            public let currentValueLabel: Node?
            public let minimumValueLabel: Node?
            public let maximumValueLabel: Node?
        }

        public struct Chart: Sendable {
            public static let maximumMarks = 8
            public static let maximumValues = 100

            public struct Mark: Sendable {
                public enum Kind: String, Choice { case line, area, bar, point, rule, sector }
                public enum Interpolation: String, Choice { case linear, monotone, catmullRom, cardinal, stepStart, stepCenter, stepEnd }

                public let kind: Kind
                public let values: [Double]
                public let color: Paint?
                public let colors: [ColorValue]
                public let lineWidth: Double
                public let interpolation: Interpolation
                public let cornerRadius: Double
                public let innerRadius: Double
            }

            public let marks: [Mark]
            public let range: ClosedRange<Double>?
            public let axes: Bool
        }

        static let fields: [String: Set<String>] = [
            "text": [], "concat": [], "spacer": [], "divider": [], "svg": [],
            "symbol": ["value"],
            "timer": ["countsDown", "pausedAt", "showsHours"],
            "date": ["style"],
            "shape": ["cornerRadius", "fill", "stroke", "lineWidth", "lineCap", "dash", "trim"],
            "hstack": ["alignment", "spacing"],
            "vstack": ["alignment", "spacing"],
            "zstack": ["alignment"],
            "progress": ["style", "countsDown", "pausedAt"],
            "gauge": ["min", "max", "style", "label", "currentValueLabel", "minimumValueLabel", "maximumValueLabel"],
            "viewThatFits": ["in"],
            "if": ["then", "else"],
            "link": ["label"],
            "button": ["label", "style"],
            "toggle": ["isOn", "label", "style"],
            "grid": ["alignment", "horizontalSpacing", "verticalSpacing"],
            "chart": ["min", "max", "axes"],
        ]

        init(_ kind: String, _ fields: Fields) throws {
            switch kind {
            case "text":
                let text = (try? fields.required(kind) as String) ?? (try? fields.required(kind) as Double)?.textValue
                guard let text else { throw fields.invalid("expected text or a number", at: kind) }
                self = .text(text)
            case "symbol":
                let value: Double? = try fields.optional("value")
                guard value.map((0...1).contains) != false else { throw fields.invalid("expected a value within 0...1", at: "value") }
                self = .symbol(try fields.required(kind), value: value)
            case "timer":
                self = .timer(try fields.interval(kind), countsDown: try fields.optional("countsDown") ?? true,
                              pausedAt: try fields.optional("pausedAt"), showsHours: try fields.optional("showsHours") ?? true)
            case "date": self = .date(try fields.required(kind), style: try fields.optional("style") ?? .time)
            case "concat":
                let parts: [Node] = try fields.required(kind)
                guard parts.allSatisfy(\.isInline) else {
                    throw fields.invalid("parts must be text, symbol, date or timer nodes with text modifiers", at: kind)
                }
                self = .concat(parts)
            case "shape":
                let shape: Shape.Kind = try fields.required(kind)
                let trim: [Double] = try fields.optional("trim") ?? [0, 1]
                guard trim.count == 2, 0 <= trim[0], trim[0] <= trim[1], trim[1] <= 1 else {
                    throw fields.invalid("expected [from, to] within 0...1", at: "trim")
                }
                let cornerRadius: Double? = try fields.optional("cornerRadius")
                guard cornerRadius == nil || shape == .roundedRectangle else {
                    throw fields.invalid("only roundedRectangle has a corner radius", at: "cornerRadius")
                }
                self = .shape(Shape(kind: shape, cornerRadius: cornerRadius ?? 8, fill: try fields.optional("fill"),
                                    stroke: try fields.optional("stroke"), lineWidth: try fields.optional("lineWidth") ?? 1,
                                    lineCap: try fields.optional("lineCap") ?? .butt, dash: try fields.optional("dash") ?? [],
                                    trim: trim[0]...trim[1]))
            case "svg":
                let markup: String = try fields.required(kind)
                do throws(LayoutError) {
                    self = .svg(try Drawing(svg: markup))
                } catch {
                    throw fields.invalid(error.description, at: kind)
                }
            case "hstack":
                self = .hstack(try fields.required(kind), alignment: try fields.optional("alignment") ?? .center,
                               spacing: try fields.optional("spacing"))
            case "vstack":
                self = .vstack(try fields.required(kind), alignment: try fields.optional("alignment") ?? .center,
                               spacing: try fields.optional("spacing"))
            case "zstack": self = .zstack(try fields.required(kind), alignment: try fields.optional("alignment") ?? .center)
            case "spacer":
                if let length = try? fields.required(kind) as Double { self = .spacer(minLength: length) }
                else if try fields.required(kind) as Bool { self = .spacer(minLength: nil) }
                else { throw fields.invalid("expected true or a minimum length", at: kind) }
            case "divider":
                guard try fields.required(kind) as Bool else { throw fields.invalid("expected true", at: kind) }
                self = .divider
            case "progress":
                let style: ProgressStyle = try fields.optional("style") ?? .linear
                if let value = try? fields.required(kind) as Double {
                    guard (0...1).contains(value) else { throw fields.invalid("expected a value within 0...1", at: kind) }
                    guard fields.allKeys.allSatisfy({ !["countsDown", "pausedAt"].contains($0.stringValue) }) else {
                        throw fields.invalid("countsDown and pausedAt apply only to a [start, end] progress")
                    }
                    self = .progress(.value(value), style: style)
                } else {
                    self = .progress(.interval(try fields.interval(kind), countsDown: try fields.optional("countsDown") ?? false,
                                               pausedAt: try fields.optional("pausedAt")), style: style)
                }
            case "gauge":
                let minimum: Double = try fields.optional("min") ?? 0
                let maximum: Double = try fields.optional("max") ?? 1
                guard minimum < maximum else { throw fields.invalid("min must be less than max", at: "max") }
                self = .gauge(Gauge(value: try fields.required(kind), range: minimum...maximum,
                                    style: try fields.optional("style") ?? .circular, label: try fields.optional("label"),
                                    currentValueLabel: try fields.optional("currentValueLabel"),
                                    minimumValueLabel: try fields.optional("minimumValueLabel"),
                                    maximumValueLabel: try fields.optional("maximumValueLabel")))
            case "viewThatFits": self = .viewThatFits(try fields.required(kind), axis: try fields.optional("in"))
            case "link":
                guard let url = try fields.link(kind) else { throw fields.invalid("expected a URL", at: kind) }
                self = .link(url, label: try fields.control(kind))
            case "button":
                let name: String = try fields.required(kind)
                guard Self.isName(name) else { throw fields.invalid("use 1 to 64 lowercase letters, digits, '-', '_' or '.'", at: kind) }
                self = .button(name, label: try fields.control(kind), style: try fields.optional("style") ?? .automatic)
            case "toggle":
                let path: String = try fields.required(kind)
                guard (1...256).contains(path.utf8.count) else { throw fields.invalid("expected a data path of at most 256 bytes", at: kind) }
                self = .toggle(path, isOn: try fields.required("isOn"), label: try fields.control(kind), style: try fields.optional("style") ?? .switch)
            case "grid":
                self = .grid(try fields.required(kind), alignment: try fields.optional("alignment") ?? .center,
                             horizontalSpacing: try fields.optional("horizontalSpacing"), verticalSpacing: try fields.optional("verticalSpacing"))
            case "chart":
                let marks: [ChartMark] = try fields.required(kind)
                guard (1...Chart.maximumMarks).contains(marks.count) else { throw fields.invalid("expected 1 to \(Chart.maximumMarks) marks", at: kind) }
                let minimum: Double? = try fields.optional("min")
                let maximum: Double? = try fields.optional("max")
                guard (minimum == nil) == (maximum == nil) else { throw fields.invalid("give both min and max, or neither") }
                guard minimum.map({ $0 < maximum! }) != false else { throw fields.invalid("min must be less than max", at: "max") }
                self = .chart(Chart(marks: marks.map(\.mark), range: minimum.map { $0...maximum! }, axes: try fields.optional("axes") ?? false))
            default: self = .conditional(try fields.required(kind), then: try fields.required("then"), else: try fields.optional("else"))
            }
        }

        static func isName(_ text: String) -> Bool {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_.".utf8)
            return (1...64).contains(text.utf8.count) && text.utf8.allSatisfy(allowed.contains)
        }

        var children: [Node] {
            switch self {
            case let .concat(nodes), let .hstack(nodes, _, _), let .vstack(nodes, _, _), let .zstack(nodes, _),
                 let .viewThatFits(nodes, _):
                nodes
            case let .gauge(gauge):
                [gauge.label, gauge.currentValueLabel, gauge.minimumValueLabel, gauge.maximumValueLabel].compactMap(\.self)
            case let .conditional(_, then, otherwise): [then] + [otherwise].compactMap(\.self)
            case let .link(_, label), let .button(_, label, _), let .toggle(_, _, label, _): [label]
            case let .grid(rows, _, _, _): rows.flatMap(\.self)
            case .text, .symbol, .timer, .date, .shape, .svg, .spacer, .divider, .progress, .chart: []
            }
        }
    }
}

private struct ChartMark: Decodable {
    let mark: Node.Content.Chart.Mark

    init(from decoder: any Decoder) throws {
        typealias Mark = Node.Content.Chart.Mark
        let fields = try decoder.container(keyedBy: Key.self)
        let kinds = fields.allKeys.compactMap { Mark.Kind(rawValue: $0.stringValue) }
        guard kinds.count == 1, let kind = kinds.first else {
            throw fields.invalid("a mark is an object with one of \(Mark.Kind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let allowed: Set<String> = switch kind {
        case .line: ["color", "lineWidth", "interpolation"]
        case .area: ["color", "interpolation"]
        case .bar: ["color", "colors", "cornerRadius"]
        case .point: ["color", "colors"]
        case .rule: ["color", "lineWidth"]
        case .sector: ["colors", "innerRadius"]
        }
        try fields.allowOnly(allowed.union([kind.rawValue]))
        let values: [Double] = if kind == .rule { [try fields.required(kind.rawValue)] } else { try fields.required(kind.rawValue) }
        guard (1...Node.Content.Chart.maximumValues).contains(values.count), values.allSatisfy(\.isFinite) else {
            throw fields.invalid("expected 1 to \(Node.Content.Chart.maximumValues) numbers", at: kind.rawValue)
        }
        guard kind != .sector || values.allSatisfy({ $0 >= 0 }) else { throw fields.invalid("sector values must not be negative", at: kind.rawValue) }
        let colors: [ColorValue] = try fields.optional("colors") ?? []
        guard colors.isEmpty || colors.count == values.count else { throw fields.invalid("give one color per value", at: "colors") }
        let innerRadius: Double = try fields.optional("innerRadius") ?? 0
        guard (0..<1).contains(innerRadius) else { throw fields.invalid("expected a fraction from 0 up to 1", at: "innerRadius") }
        mark = Mark(kind: kind, values: values, color: try fields.optional("color"), colors: colors,
                    lineWidth: try fields.optional("lineWidth") ?? 2, interpolation: try fields.optional("interpolation") ?? .linear,
                    cornerRadius: try fields.optional("cornerRadius") ?? 0, innerRadius: innerRadius)
    }
}

extension KeyedDecodingContainer<Key> {
    func link(_ key: String) throws -> URL? {
        guard let text: String = try optional(key) else { return nil }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              !["http", "file", "data", "javascript", "about", "blob"].contains(scheme) else {
            throw invalid("expected an https URL or an app URL such as shortcuts://", at: key)
        }
        return url
    }

    func control(_ kind: String) throws -> Node {
        guard codingPath.first.map({ ["lockScreen", "expanded"].contains($0.stringValue) }) == true else {
            throw invalid("links, buttons and toggles work only in lockScreen and expanded", at: kind)
        }
        let label: Node = try required("label")
        guard !label.descendants.contains(where: \.isControl) else {
            throw invalid("a label cannot contain links, buttons or toggles", at: "label")
        }
        return label
    }

    func interval(_ key: String) throws -> ClosedRange<Date> {
        let dates: [Date] = try required(key)
        guard dates.count == 2, dates[0] <= dates[1] else { throw invalid("expected [start, end] with start before end", at: key) }
        return dates[0]...dates[1]
    }
}
