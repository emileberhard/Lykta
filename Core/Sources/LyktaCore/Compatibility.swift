import Synchronization

public struct Version: Comparable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ text: some StringProtocol) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { part in part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) ? Int(part) : nil }
        guard parts.count == 3, numbers.count == 3 else { return nil }
        self.init(numbers[0], numbers[1], numbers[2])
    }

    public init?(leading text: String) {
        guard let first = text.split(separator: " ", maxSplits: 1).first else { return nil }
        self.init(first)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let version = Version(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected MAJOR.MINOR.PATCH")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: Version, rhs: Version) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension Layout {
    public struct Requirement: Equatable, Sendable {
        public let version: Version
        public let feature: String
        public let path: String
    }

    public static let version = introduced.values.max()!
    static let baseline = introduced.values.min()!

    static let introduced: [String: Version] = Dictionary(uniqueKeysWithValues: [
        "0.2.2": [
            "concat", "date", "date.style", "divider", "expanded.bottom", "expanded.center", "expanded.leading",
            "expanded.trailing", "gauge", "gauge.currentValueLabel", "gauge.label", "gauge.max",
            "gauge.maximumValueLabel", "gauge.min", "gauge.minimumValueLabel", "gauge.style", "hstack",
            "hstack.alignment", "hstack.spacing", "if", "if.else", "if.then", "layout.background",
            "layout.compactLeading", "layout.compactTrailing", "layout.expanded", "layout.keyline", "layout.link",
            "layout.lockScreen", "layout.minimal", "layout.small", "modifiers.accessibilityLabel",
            "modifiers.background", "modifiers.bold", "modifiers.clip", "modifiers.contentTransition",
            "modifiers.fixedSize", "modifiers.font", "modifiers.fontDesign", "modifiers.fontWeight",
            "modifiers.fontWidth", "modifiers.foreground", "modifiers.frame", "modifiers.frame.alignment",
            "modifiers.frame.height", "modifiers.frame.maxHeight", "modifiers.frame.maxWidth",
            "modifiers.frame.minHeight", "modifiers.frame.minWidth", "modifiers.frame.width", "modifiers.imageScale",
            "modifiers.italic", "modifiers.layoutPriority", "modifiers.lineLimit", "modifiers.minimumScaleFactor",
            "modifiers.monospacedDigit", "modifiers.multilineTextAlignment", "modifiers.offset", "modifiers.opacity",
            "modifiers.padding", "modifiers.padding.bottom", "modifiers.padding.horizontal",
            "modifiers.padding.leading", "modifiers.padding.top", "modifiers.padding.trailing",
            "modifiers.padding.vertical", "modifiers.rotation", "modifiers.scale", "modifiers.shadow",
            "modifiers.shadow.color", "modifiers.shadow.radius", "modifiers.shadow.x", "modifiers.shadow.y",
            "modifiers.strikethrough", "modifiers.symbolRenderingMode", "modifiers.textCase", "modifiers.tint",
            "modifiers.tracking", "modifiers.truncationMode", "modifiers.underline", "paint.direction",
            "paint.gradient", "progress", "progress.countsDown", "progress.pausedAt", "progress.style", "shape",
            "shape.cornerRadius", "shape.dash", "shape.fill", "shape.lineCap", "shape.lineWidth", "shape.stroke",
            "shape.trim", "spacer", "symbol", "text", "timer", "timer.countsDown", "timer.pausedAt",
            "timer.showsHours", "viewThatFits", "viewThatFits.in", "vstack", "vstack.alignment", "vstack.spacing",
            "zstack", "zstack.alignment",
            "ColorValue.Name.accent", "ColorValue.Name.black", "ColorValue.Name.blue", "ColorValue.Name.brown",
            "ColorValue.Name.clear", "ColorValue.Name.cyan", "ColorValue.Name.gray", "ColorValue.Name.green",
            "ColorValue.Name.indigo", "ColorValue.Name.mint", "ColorValue.Name.orange", "ColorValue.Name.pink",
            "ColorValue.Name.purple", "ColorValue.Name.red", "ColorValue.Name.teal", "ColorValue.Name.white",
            "ColorValue.Name.yellow", "Modifier.ContentTransition.Name.identity",
            "Modifier.ContentTransition.Name.interpolate", "Modifier.ContentTransition.Name.numericText",
            "Modifier.ContentTransition.Name.opacity", "Modifier.Design.default", "Modifier.Design.monospaced",
            "Modifier.Design.rounded", "Modifier.Design.serif", "Modifier.Font.Style.body",
            "Modifier.Font.Style.callout", "Modifier.Font.Style.caption", "Modifier.Font.Style.caption2",
            "Modifier.Font.Style.footnote", "Modifier.Font.Style.headline", "Modifier.Font.Style.largeTitle",
            "Modifier.Font.Style.subheadline", "Modifier.Font.Style.title", "Modifier.Font.Style.title2",
            "Modifier.Font.Style.title3", "Modifier.ImageScale.large", "Modifier.ImageScale.medium",
            "Modifier.ImageScale.small", "Modifier.SymbolRendering.hierarchical",
            "Modifier.SymbolRendering.monochrome", "Modifier.SymbolRendering.multicolor",
            "Modifier.SymbolRendering.palette", "Modifier.TextCase.lowercase", "Modifier.TextCase.uppercase",
            "Modifier.Truncation.head", "Modifier.Truncation.middle", "Modifier.Truncation.tail",
            "Modifier.Weight.black", "Modifier.Weight.bold", "Modifier.Weight.heavy", "Modifier.Weight.light",
            "Modifier.Weight.medium", "Modifier.Weight.regular", "Modifier.Weight.semibold", "Modifier.Weight.thin",
            "Modifier.Weight.ultraLight", "Modifier.Width.compressed", "Modifier.Width.condensed",
            "Modifier.Width.expanded", "Modifier.Width.standard", "Node.Content.Alignment.bottom",
            "Node.Content.Alignment.bottomLeading", "Node.Content.Alignment.bottomTrailing",
            "Node.Content.Alignment.center", "Node.Content.Alignment.leading", "Node.Content.Alignment.top",
            "Node.Content.Alignment.topLeading", "Node.Content.Alignment.topTrailing",
            "Node.Content.Alignment.trailing", "Node.Content.Axis.horizontal", "Node.Content.Axis.vertical",
            "Node.Content.Condition.Environment.dark", "Node.Content.Condition.Environment.fullscreen",
            "Node.Content.Condition.Environment.limitedWidth", "Node.Content.Condition.Environment.luminanceReduced",
            "Node.Content.Condition.Environment.stale", "Node.Content.DateStyle.date", "Node.Content.DateStyle.offset",
            "Node.Content.DateStyle.relative", "Node.Content.DateStyle.time", "Node.Content.DateStyle.timer",
            "Node.Content.Gauge.Style.circular", "Node.Content.Gauge.Style.circularCapacity",
            "Node.Content.Gauge.Style.linear", "Node.Content.Gauge.Style.linearCapacity",
            "Node.Content.HorizontalAlignment.center", "Node.Content.HorizontalAlignment.leading",
            "Node.Content.HorizontalAlignment.trailing", "Node.Content.ProgressStyle.circular",
            "Node.Content.ProgressStyle.linear", "Node.Content.Shape.Kind.capsule", "Node.Content.Shape.Kind.circle",
            "Node.Content.Shape.Kind.containerRelativeShape", "Node.Content.Shape.Kind.ellipse",
            "Node.Content.Shape.Kind.rectangle", "Node.Content.Shape.Kind.roundedRectangle",
            "Node.Content.Shape.LineCap.butt", "Node.Content.Shape.LineCap.round", "Node.Content.Shape.LineCap.square",
            "Node.Content.VerticalAlignment.bottom", "Node.Content.VerticalAlignment.center",
            "Node.Content.VerticalAlignment.firstTextBaseline", "Node.Content.VerticalAlignment.lastTextBaseline",
            "Node.Content.VerticalAlignment.top", "Paint.Direction.angular", "Paint.Direction.diagonal",
            "Paint.Direction.horizontal", "Paint.Direction.radial", "Paint.Direction.vertical", "Paint.Level.primary",
            "Paint.Level.quaternary", "Paint.Level.secondary", "Paint.Level.tertiary",
        ],
        "0.2.3": [
            "button", "button.label", "button.style", "chart", "chart.area.color", "chart.area.interpolation",
            "chart.axes", "chart.bar.color", "chart.bar.colors", "chart.bar.cornerRadius", "chart.line.color",
            "chart.line.interpolation", "chart.line.lineWidth", "chart.max", "chart.min", "chart.point.color",
            "chart.point.colors", "chart.rule.color", "chart.rule.lineWidth", "chart.sector.colors",
            "chart.sector.innerRadius", "grid", "grid.alignment", "grid.horizontalSpacing", "grid.verticalSpacing",
            "if.bool", "layout.link.appURL", "link", "link.label", "modifiers.animation", "modifiers.animation.curve",
            "modifiers.animation.delay", "modifiers.animation.duration", "modifiers.animation.value", "modifiers.blur",
            "modifiers.brightness", "modifiers.contentTransition.numericText", "modifiers.grayscale", "modifiers.id",
            "modifiers.overlay", "modifiers.saturation", "modifiers.transition", "modifiers.transition.move",
            "modifiers.transition.push", "number", "symbol.value", "text.number", "toggle", "toggle.isOn",
            "toggle.label", "toggle.style",
            "Modifier.Animation.Curve.bouncy", "Modifier.Animation.Curve.default", "Modifier.Animation.Curve.easeIn",
            "Modifier.Animation.Curve.easeInOut", "Modifier.Animation.Curve.easeOut",
            "Modifier.Animation.Curve.linear", "Modifier.Animation.Curve.smooth", "Modifier.Animation.Curve.snappy",
            "Modifier.Animation.Curve.spring", "Modifier.ContentTransition.Name.symbolReplace",
            "Modifier.Transition.Edge.bottom", "Modifier.Transition.Edge.leading", "Modifier.Transition.Edge.top",
            "Modifier.Transition.Edge.trailing", "Modifier.Transition.Name.identity",
            "Modifier.Transition.Name.opacity", "Modifier.Transition.Name.scale", "Modifier.Transition.Name.slide",
            "Node.Content.ButtonStyle.automatic", "Node.Content.ButtonStyle.bordered",
            "Node.Content.ButtonStyle.borderedProminent", "Node.Content.ButtonStyle.plain",
            "Node.Content.Chart.Mark.Interpolation.cardinal", "Node.Content.Chart.Mark.Interpolation.catmullRom",
            "Node.Content.Chart.Mark.Interpolation.linear", "Node.Content.Chart.Mark.Interpolation.monotone",
            "Node.Content.Chart.Mark.Interpolation.stepCenter", "Node.Content.Chart.Mark.Interpolation.stepEnd",
            "Node.Content.Chart.Mark.Interpolation.stepStart", "Node.Content.Chart.Mark.Kind.area",
            "Node.Content.Chart.Mark.Kind.bar", "Node.Content.Chart.Mark.Kind.line",
            "Node.Content.Chart.Mark.Kind.point", "Node.Content.Chart.Mark.Kind.rule",
            "Node.Content.Chart.Mark.Kind.sector", "Node.Content.ToggleStyle.button",
            "Node.Content.ToggleStyle.checkbox", "Node.Content.ToggleStyle.switch",
        ],
        "0.2.4": [
            "color.rgb", "color.shortHex", "svg",
        ],
        "0.5.0": [
            "button.add", "button.add.since", "button.now", "button.set",
        ],
        "0.8.0": [
            "paint.mesh",
        ],
    ].flatMap { version, features in features.map { ($0, Version(version)!) } })
}

final class FeatureLog: Sendable {
    @TaskLocal static var current: FeatureLog?

    private let entries = Mutex<[(feature: String, path: String)]>([])

    static func record(_ feature: String, at path: [any CodingKey]) {
        current?.entries.withLock { $0.append((feature, LayoutError.path(path))) }
    }

    var features: [String] {
        entries.withLock { $0.map(\.feature) }
    }

    var requirement: Layout.Requirement? {
        entries.withLock { entries in
            entries.reduce(nil) { (newest: Layout.Requirement?, entry) in
                guard let version = Layout.introduced[entry.feature],
                      version > (newest?.version ?? Layout.baseline) else { return newest }
                return Layout.Requirement(version: version, feature: entry.feature, path: entry.path)
            }
        }
    }
}

extension KeyedDecodingContainer<Key> {
    func record(_ feature: String, at key: String? = nil) {
        FeatureLog.record(feature, at: codingPath + (key.map { [Key(stringValue: $0)] } ?? []))
    }

    func recordKeys(in context: String, except excluded: Set<String> = []) {
        for key in allKeys where !excluded.contains(key.stringValue) {
            record("\(context).\(key.stringValue)", at: key.stringValue)
        }
    }
}
