import Foundation

extension Drawing {
    public init(svg markup: String) throws(LayoutError) {
        let root = try MarkupReader.document(markup)
        guard root.name == "svg" else { throw LayoutError("the root element is <\(root.name)>; expected <svg>") }
        do {
            var reader = try SVGReader(root: root)
            try reader.visit(root, inheriting: SVGStyle(), transform: .identity, opacity: 1, blur: 0)
            self.init(viewBox: reader.viewBox, size: reader.size, items: reader.items)
        } catch let error as LayoutError {
            throw error
        } catch {
            throw LayoutError("\(error)")
        }
    }
}

private struct SVGStyle {
    enum Source {
        case color(ColorValue)
        case foreground
        case gradient(String)
    }

    var fill: Source? = .color(.rgb(red: 0, green: 0, blue: 0, opacity: 1))
    var fillOpacity = 1.0
    var evenOdd = false
    var stroke: Source?
    var strokeOpacity = 1.0
    var strokeWidth = 1.0
    var cap = Node.Content.Shape.LineCap.butt
    var join = Drawing.LineJoin.miter
    var miterLimit = 4.0
    var dash: [Double] = []
    var dashOffset = 0.0
    var fontSize = 16.0
    var weight = Modifier.Weight.regular
    var design = Modifier.Design.default
    var anchor = Drawing.Label.Anchor.start
    var baseline = Drawing.Label.Baseline.alphabetic
}

private struct SVGReader {
    private enum Dimension { case horizontal, vertical, diagonal }

    private static let presentation: Set<String> = [
        "id", "style", "transform", "opacity", "filter", "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width",
        "stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset",
        "font-size", "font-weight", "font-family", "text-anchor", "dominant-baseline",
    ]
    private static let shapes: [String: Set<String>] = [
        "path": ["d", "pathLength"], "rect": ["x", "y", "width", "height", "rx", "ry", "pathLength"],
        "circle": ["cx", "cy", "r", "pathLength"], "ellipse": ["cx", "cy", "rx", "ry", "pathLength"],
        "line": ["x1", "y1", "x2", "y2", "pathLength"], "polyline": ["points", "pathLength"], "polygon": ["points", "pathLength"],
    ]
    private static let elements = "svg, g, path, rect, circle, ellipse, line, polyline, polygon, text, defs, linearGradient, radialGradient, stop, filter, feGaussianBlur, title, desc"

    let viewBox: Drawing.Rect
    let size: (width: Double, height: Double)?
    private(set) var items: [Drawing.Item] = []
    private var gradients: [String: (gradient: Drawing.Gradient, usesBoundingBox: Bool)] = [:]
    private var blurs: [String: Double] = [:]
    private var segments = 0
    private var counts: [String: Int] = [:]

    init(root: MarkupElement) throws {
        let width = try Self.size(root.attributes["width"], "width")
        let height = try Self.size(root.attributes["height"], "height")
        if let text = root.attributes["viewBox"] {
            guard let numbers = NumberScanner.numbers(text), numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else {
                throw LayoutError("<svg> viewBox: expected \"x y width height\" with a positive width and height")
            }
            viewBox = Drawing.Rect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        } else if let width, let height {
            viewBox = Drawing.Rect(x: 0, y: 0, width: width, height: height)
        } else {
            throw LayoutError("<svg>: give a viewBox, such as viewBox=\"0 0 24 24\"")
        }
        size = switch (width, height) {
        case let (width?, height?): (width, height)
        case let (width?, nil): (width, width * viewBox.height / viewBox.width)
        case let (nil, height?): (height * viewBox.width / viewBox.height, height)
        case (nil, nil): nil
        }
        try define(root)
    }

    mutating func visit(_ element: MarkupElement, inheriting inherited: SVGStyle, transform: Drawing.Transform,
                        opacity: Double, blur: Double) throws {
        counts[element.name, default: 0] += 1
        let label = element.attributes["id"].map { "<\(element.name) id=\"\($0)\">" } ?? "<\(element.name)> #\(counts[element.name]!)"
        switch element.name {
        case "svg" where counts["svg"] == 1, "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text":
            let context: (style: SVGStyle, transform: Drawing.Transform, opacity: Double, blur: Double)
            do {
                context = try draw(element, inheriting: inherited, transform: transform, opacity: opacity, blur: blur)
            } catch let error as LayoutError {
                throw LayoutError("\(label): \(error.description)")
            }
            guard ["svg", "g"].contains(element.name) else { return }
            for child in element.children {
                try visit(child, inheriting: context.style, transform: context.transform, opacity: context.opacity, blur: context.blur)
            }
        case "defs":
            if let child = element.children.first(where: { !["linearGradient", "radialGradient", "filter", "title", "desc"].contains($0.name) }) {
                throw LayoutError("\(label): <defs> holds only gradients and filters, not <\(child.name)>")
            }
        case "linearGradient", "radialGradient", "filter", "title", "desc":
            break
        default:
            throw LayoutError("<\(element.name)> is not supported; use \(Self.elements)")
        }
    }

    private mutating func draw(_ element: MarkupElement, inheriting inherited: SVGStyle, transform: Drawing.Transform, opacity: Double,
                               blur: Double) throws -> (style: SVGStyle, transform: Drawing.Transform, opacity: Double, blur: Double) {
        let extra: Set<String> = switch element.name {
        case "svg": ["viewBox", "width", "height", "version"]
        case "g": []
        case "text": ["x", "y"]
        default: Self.shapes[element.name]!
        }
        let attributes = try Self.attributes(of: element, allowing: Self.presentation.union(extra))
        let style = try self.style(inherited, attributes)
        var transform = transform, opacity = opacity, blur = blur
        if let text = attributes["transform"] { transform = transform.concatenating(try Self.transform(text)) }
        if let text = attributes["opacity"] { opacity *= try Self.fraction(text, "opacity") }
        if let text = attributes["filter"] { blur = try self.blur(text) }
        if !["svg", "g"].contains(element.name) {
            if let child = element.children.first(where: { !["title", "desc"].contains($0.name) }) {
                throw LayoutError("<\(child.name)> is not supported inside <\(element.name)>\(element.name == "text" ? "; use one <text> per line" : "")")
            }
            let shape: Drawing.Item.Shape? = element.name == "text" ? try label(element, attributes, style) : try path(element.name, attributes).map { .path($0) }
            if let shape { try add(shape, attributes: attributes, style: style, transform: transform, opacity: opacity, blur: blur) }
        }
        return (style, transform, opacity, blur)
    }

    private mutating func add(_ shape: Drawing.Item.Shape, attributes: [String: String], style: SVGStyle,
                              transform: Drawing.Transform, opacity: Double, blur: Double) throws {
        let segments: [Drawing.Segment] = if case let .path(segments) = shape { segments } else { [] }
        let (length, bounds) = Drawing.measure(segments)
        let fill = style.fill.map { Drawing.Fill(paint: paint($0, bounds), opacity: style.fillOpacity, evenOdd: style.evenOdd) }
        let pathLength = try attributes["pathLength"].map { try Self.number($0, "pathLength") }
        guard pathLength.map({ $0 > 0 }) != false else { throw LayoutError("pathLength: expected a positive number") }
        let scale = pathLength.map { length / $0 } ?? 1
        var stroke: Drawing.Stroke?
        if let source = style.stroke, style.strokeWidth > 0, case .path = shape {
            var dash = style.dash.map { $0 * scale }
            if dash.count.isMultiple(of: 2) == false { dash += dash }
            let period = dash.reduce(0, +)
            let phase = period > 0 ? (style.dashOffset * scale).truncatingRemainder(dividingBy: period) : 0
            stroke = Drawing.Stroke(paint: paint(source, bounds), opacity: style.strokeOpacity, width: style.strokeWidth, cap: style.cap,
                                    join: style.join, miterLimit: style.miterLimit, dash: period > 0 ? dash : [],
                                    dashPhase: phase < 0 ? phase + period : phase)
        }
        guard fill != nil || stroke != nil else { return }
        self.segments += segments.count
        items.append(Drawing.Item(shape: shape, fill: fill, stroke: stroke, opacity: opacity, blur: blur, transform: transform))
        guard items.count <= Drawing.maximumItems else { throw LayoutError("the svg draws more than \(Drawing.maximumItems) shapes") }
        guard self.segments <= Drawing.maximumSegments else { throw LayoutError("the svg has more than \(Drawing.maximumSegments) path segments") }
    }

    private func paint(_ source: SVGStyle.Source, _ bounds: Drawing.Rect) -> Drawing.Paint {
        switch source {
        case let .color(color): .color(color)
        case .foreground: .foreground
        case let .gradient(id):
            .gradient(Drawing.Gradient(shape: gradients[id]!.gradient.shape, stops: gradients[id]!.gradient.stops,
                                       boundingBox: gradients[id]!.usesBoundingBox ? bounds : nil))
        }
    }

    private func path(_ name: String, _ attributes: [String: String]) throws -> [Drawing.Segment]? {
        func coordinate(_ key: String, _ dimension: Dimension) throws -> Double {
            try attributes[key].map { try length($0, key, dimension) } ?? 0
        }
        func positive(_ key: String, _ dimension: Dimension) throws -> Double? {
            guard let value = try attributes[key].map({ try length($0, key, dimension) }) else { return nil }
            guard value >= 0 else { throw LayoutError("\(key): must not be negative") }
            return value
        }
        typealias Point = Drawing.Point
        func ellipse(_ center: Point, _ radii: Point) -> [Drawing.Segment] {
            let start = Point(x: center.x + radii.x, y: center.y), opposite = Point(x: center.x - radii.x, y: center.y)
            return [.move(start)] + Drawing.arc(from: start, to: opposite, radii: radii, rotation: 0, large: false, sweep: true)
                + Drawing.arc(from: opposite, to: start, radii: radii, rotation: 0, large: false, sweep: true) + [.close]
        }
        switch name {
        case "path":
            guard let data = attributes["d"], !data.allSatisfy(\.isWhitespace) else { return nil }
            return try Self.pathData(data)
        case "rect":
            let x = try coordinate("x", .horizontal), y = try coordinate("y", .vertical)
            guard let width = try positive("width", .horizontal), let height = try positive("height", .vertical), width > 0, height > 0 else { return nil }
            let givenX = try positive("rx", .horizontal), givenY = try positive("ry", .vertical)
            let rx = min(givenX ?? givenY ?? 0, width / 2), ry = min(givenY ?? givenX ?? 0, height / 2)
            guard rx > 0, ry > 0 else {
                return [.move(Point(x: x, y: y)), .line(Point(x: x + width, y: y)), .line(Point(x: x + width, y: y + height)),
                        .line(Point(x: x, y: y + height)), .close]
            }
            let radii = Point(x: rx, y: ry)
            let corners = [
                (Point(x: x + width - rx, y: y), Point(x: x + width, y: y + ry)),
                (Point(x: x + width, y: y + height - ry), Point(x: x + width - rx, y: y + height)),
                (Point(x: x + rx, y: y + height), Point(x: x, y: y + height - ry)),
                (Point(x: x, y: y + ry), Point(x: x + rx, y: y)),
            ]
            return [.move(Point(x: x + rx, y: y))] + corners.flatMap { line, end in
                [.line(line)] + Drawing.arc(from: line, to: end, radii: radii, rotation: 0, large: false, sweep: true)
            } + [.close]
        case "circle":
            guard let radius = try positive("r", .diagonal), radius > 0 else { return nil }
            return ellipse(Point(x: try coordinate("cx", .horizontal), y: try coordinate("cy", .vertical)), Point(x: radius, y: radius))
        case "ellipse":
            guard let rx = try positive("rx", .horizontal), let ry = try positive("ry", .vertical), rx > 0, ry > 0 else { return nil }
            return ellipse(Point(x: try coordinate("cx", .horizontal), y: try coordinate("cy", .vertical)), Point(x: rx, y: ry))
        case "line":
            return [.move(Point(x: try coordinate("x1", .horizontal), y: try coordinate("y1", .vertical))),
                    .line(Point(x: try coordinate("x2", .horizontal), y: try coordinate("y2", .vertical)))]
        default:
            guard let numbers = NumberScanner.numbers(attributes["points"] ?? ""), numbers.count.isMultiple(of: 2) else {
                throw LayoutError("points: expected pairs of numbers such as \"0,0 10,5 20,0\"")
            }
            guard numbers.count >= 4 else { return nil }
            let points = stride(from: 0, to: numbers.count, by: 2).map { Point(x: numbers[$0], y: numbers[$0 + 1]) }
            return [.move(points[0])] + points.dropFirst().map { .line($0) } + (name == "polygon" ? [.close] : [])
        }
    }

    private func label(_ element: MarkupElement, _ attributes: [String: String], _ style: SVGStyle) throws -> Drawing.Item.Shape? {
        let text = element.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        if case .gradient = style.fill { throw LayoutError("fill: text takes a color or currentColor") }
        let position = Drawing.Point(x: try attributes["x"].map { try length($0, "x", .horizontal) } ?? 0,
                                     y: try attributes["y"].map { try length($0, "y", .vertical) } ?? 0)
        return .label(Drawing.Label(text: text, position: position, size: style.fontSize, weight: style.weight, design: style.design,
                                    anchor: style.anchor, baseline: style.baseline))
    }

    private func style(_ inherited: SVGStyle, _ attributes: [String: String]) throws -> SVGStyle {
        var style = inherited
        for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "fill": style.fill = try source(value, key)
            case "stroke": style.stroke = try source(value, key)
            case "fill-opacity": style.fillOpacity = try Self.fraction(value, key)
            case "stroke-opacity": style.strokeOpacity = try Self.fraction(value, key)
            case "fill-rule":
                guard ["nonzero", "evenodd"].contains(value) else { throw LayoutError("fill-rule: expected nonzero or evenodd") }
                style.evenOdd = value == "evenodd"
            case "stroke-width":
                style.strokeWidth = try length(value, key, .diagonal)
                guard style.strokeWidth >= 0 else { throw LayoutError("stroke-width: must not be negative") }
            case "stroke-linecap": style.cap = try Self.choice(value, key)
            case "stroke-linejoin": style.join = try Self.choice(value, key)
            case "stroke-miterlimit":
                style.miterLimit = try Self.number(value, key)
                guard style.miterLimit >= 1 else { throw LayoutError("stroke-miterlimit: must be at least 1") }
            case "stroke-dasharray":
                guard value != "none" else {
                    style.dash = []
                    continue
                }
                guard let dash = NumberScanner.numbers(value), !dash.isEmpty, dash.allSatisfy({ $0 >= 0 }) else {
                    throw LayoutError("stroke-dasharray: expected none or lengths that are not negative")
                }
                style.dash = dash
            case "stroke-dashoffset": style.dashOffset = try Self.number(value, key)
            case "font-size":
                style.fontSize = try Self.number(value, key)
                guard (1...1000).contains(style.fontSize) else { throw LayoutError("font-size: expected 1 to 1000") }
            case "font-weight":
                let weights: [String: Modifier.Weight] = [
                    "normal": .regular, "bold": .bold, "100": .ultraLight, "200": .thin, "300": .light, "400": .regular,
                    "500": .medium, "600": .semibold, "700": .bold, "800": .heavy, "900": .black,
                ]
                guard let weight = weights[value] else { throw LayoutError("font-weight: expected normal, bold or 100 to 900 in hundreds") }
                style.weight = weight
            case "font-family":
                let designs: [String: Modifier.Design] = [
                    "serif": .serif, "ui-serif": .serif, "monospace": .monospaced, "ui-monospace": .monospaced, "ui-rounded": .rounded,
                    "sans-serif": .default, "ui-sans-serif": .default, "system-ui": .default, "-apple-system": .default,
                ]
                style.design = value.split(separator: ",").lazy
                    .compactMap { designs[$0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))] }.first ?? .default
            case "text-anchor": style.anchor = try Self.choice(value, key)
            case "dominant-baseline":
                let baselines: [String: Drawing.Label.Baseline] = [
                    "auto": .alphabetic, "alphabetic": .alphabetic, "middle": .middle, "central": .middle,
                    "hanging": .hanging, "text-before-edge": .hanging,
                ]
                guard let baseline = baselines[value] else { throw LayoutError("dominant-baseline: expected auto, middle, central or hanging") }
                style.baseline = baseline
            default: break
            }
        }
        return style
    }

    private func source(_ value: String, _ key: String) throws -> SVGStyle.Source? {
        switch value {
        case "none", "transparent": return nil
        case "currentColor": return .foreground
        default:
            if value.hasPrefix("url(#"), value.hasSuffix(")") {
                let id = String(value.dropFirst(5).dropLast())
                guard gradients[id] != nil else { throw LayoutError("\(key): no gradient has id \"\(id)\"") }
                return .gradient(id)
            }
            guard let color = ColorValue(value) else { throw LayoutError("\(key): expected none, currentColor, url(#gradient) or \(ColorValue.forms)") }
            return .color(color)
        }
    }

    private func blur(_ value: String) throws -> Double {
        guard value != "none" else { return 0 }
        guard value.hasPrefix("url(#"), value.hasSuffix(")"), let blur = blurs[String(value.dropFirst(5).dropLast())] else {
            throw LayoutError("filter: expected none or url(#id) of a <filter>")
        }
        return blur
    }

    private func length(_ text: String, _ key: String, _ dimension: Dimension) throws -> Double {
        guard text.hasSuffix("%") else { return try Self.number(text, key) }
        let reference = switch dimension {
        case .horizontal: viewBox.width
        case .vertical: viewBox.height
        case .diagonal: ((viewBox.width * viewBox.width + viewBox.height * viewBox.height) / 2).squareRoot()
        }
        return try Self.number(String(text.dropLast()), key) / 100 * reference
    }

    private mutating func define(_ element: MarkupElement) throws {
        if ["linearGradient", "radialGradient", "filter"].contains(element.name) {
            guard let id = element.attributes["id"], !id.isEmpty else { throw LayoutError("<\(element.name)> needs an id to be used") }
            do {
                if element.name == "filter" { blurs[id] = try Self.filter(element) } else { gradients[id] = try gradient(element) }
            } catch let error as LayoutError {
                throw LayoutError("<\(element.name) id=\"\(id)\">: \(error.description)")
            }
        } else {
            for child in element.children { try define(child) }
        }
    }

    private func gradient(_ element: MarkupElement) throws -> (gradient: Drawing.Gradient, usesBoundingBox: Bool) {
        let linear = element.name == "linearGradient"
        let attributes = try Self.attributes(of: element, allowing: linear ? ["id", "x1", "y1", "x2", "y2", "gradientUnits"] : ["id", "cx", "cy", "r", "gradientUnits"])
        guard ["objectBoundingBox", "userSpaceOnUse"].contains(attributes["gradientUnits"] ?? "objectBoundingBox") else {
            throw LayoutError("gradientUnits: expected objectBoundingBox or userSpaceOnUse")
        }
        let usesBoundingBox = attributes["gradientUnits"] != "userSpaceOnUse"
        func coordinate(_ key: String, _ fallback: Double, _ dimension: Dimension) throws -> Double {
            guard let text = attributes[key] else { return usesBoundingBox ? fallback : try length("\(fallback * 100)%", key, dimension) }
            if usesBoundingBox, text.hasSuffix("%") { return try Self.number(String(text.dropLast()), key) / 100 }
            return usesBoundingBox ? try Self.number(text, key) : try length(text, key, dimension)
        }
        let shape: Drawing.Gradient.Shape = if linear {
            .linear(from: Drawing.Point(x: try coordinate("x1", 0, .horizontal), y: try coordinate("y1", 0, .vertical)),
                    to: Drawing.Point(x: try coordinate("x2", 1, .horizontal), y: try coordinate("y2", 0, .vertical)))
        } else {
            .radial(center: Drawing.Point(x: try coordinate("cx", 0.5, .horizontal), y: try coordinate("cy", 0.5, .vertical)),
                    radius: try coordinate("r", 0.5, .diagonal))
        }
        var stops: [Drawing.Gradient.Stop] = []
        for child in element.children {
            guard child.name == "stop" else { throw LayoutError("<\(child.name)> is not supported in a gradient; use <stop>") }
            let attributes = try Self.attributes(of: child, allowing: ["offset", "stop-color", "stop-opacity"])
            var offset = try attributes["offset"].map { text in
                text.hasSuffix("%") ? try Self.number(String(text.dropLast()), "offset") / 100 : try Self.number(text, "offset")
            } ?? 0
            offset = min(max(offset, stops.last?.offset ?? 0), 1)
            guard let color = ColorValue(attributes["stop-color"] ?? "black") else { throw LayoutError("<stop> stop-color: expected \(ColorValue.forms)") }
            let opacity = try attributes["stop-opacity"].map { try Self.fraction($0, "stop-opacity") } ?? 1
            stops.append(Drawing.Gradient.Stop(offset: offset, color: color, opacity: opacity))
        }
        guard !stops.isEmpty else { throw LayoutError("a gradient needs at least one <stop>") }
        return (Drawing.Gradient(shape: shape, stops: stops, boundingBox: nil), usesBoundingBox)
    }

    private static func filter(_ element: MarkupElement) throws -> Double {
        _ = try attributes(of: element, allowing: ["id", "x", "y", "width", "height"])
        guard element.children.count == 1, let blur = element.children.first, blur.name == "feGaussianBlur" else {
            throw LayoutError("a filter holds exactly one <feGaussianBlur>")
        }
        let attributes = try attributes(of: blur, allowing: ["stdDeviation", "in"])
        let deviation = try number(attributes["stdDeviation"] ?? "", "stdDeviation")
        guard (0...50).contains(deviation) else { throw LayoutError("stdDeviation: expected 0 to 50") }
        return deviation
    }

    private static func attributes(of element: MarkupElement, allowing allowed: Set<String>) throws -> [String: String] {
        var attributes = element.attributes.filter { !$0.key.hasPrefix("xmlns") }
        if let style = attributes.removeValue(forKey: "style") {
            for declaration in style.split(separator: ";") where !declaration.allSatisfy(\.isWhitespace) {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { throw LayoutError("style: expected property: value; property: value") }
                attributes[parts[0]] = parts[1]
            }
        }
        if let unknown = attributes.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw LayoutError("\(unknown) is not supported here; use \(allowed.subtracting(["style"]).sorted().joined(separator: ", "))")
        }
        return attributes
    }

    private static func size(_ text: String?, _ key: String) throws -> Double? {
        guard let text, !text.hasSuffix("%") else { return nil }
        let value = try number(text, key)
        guard value > 0 else { throw LayoutError("<svg> \(key): expected a positive size") }
        return value
    }

    private static func number(_ text: String, _ key: String) throws -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed), value.isFinite else {
            throw LayoutError("\(key): expected a number, not \"\(text)\"")
        }
        return value
    }

    private static func fraction(_ text: String, _ key: String) throws -> Double {
        let value = text.hasSuffix("%") ? try number(String(text.dropLast()), key) / 100 : try number(text, key)
        return min(max(value, 0), 1)
    }

    private static func choice<T: Choice>(_ text: String, _ key: String) throws -> T {
        guard let value = T(rawValue: text) else { throw LayoutError("\(key): expected \(T.allCases.map(\.rawValue).joined(separator: ", "))") }
        return value
    }

    static func transform(_ text: String) throws -> Drawing.Transform {
        var result = Drawing.Transform.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            let values = NumberScanner.numbers(String(rest[rest.index(after: open)..<close])) ?? []
            let radians = (values.first ?? 0) * .pi / 180
            let step: Drawing.Transform? = switch (name, values.count) {
            case ("matrix", 6): Drawing.Transform(a: values[0], b: values[1], c: values[2], d: values[3], e: values[4], f: values[5])
            case ("translate", 1...2): Drawing.Transform(a: 1, b: 0, c: 0, d: 1, e: values[0], f: values.count == 2 ? values[1] : 0)
            case ("scale", 1...2): Drawing.Transform(a: values[0], b: 0, c: 0, d: values.count == 2 ? values[1] : values[0], e: 0, f: 0)
            case ("rotate", 1), ("rotate", 3):
                Drawing.Transform(a: 1, b: 0, c: 0, d: 1, e: values.count == 3 ? values[1] : 0, f: values.count == 3 ? values[2] : 0)
                    .concatenating(Drawing.Transform(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians), e: 0, f: 0))
                    .concatenating(Drawing.Transform(a: 1, b: 0, c: 0, d: 1, e: values.count == 3 ? -values[1] : 0, f: values.count == 3 ? -values[2] : 0))
            case ("skewX", 1): Drawing.Transform(a: 1, b: 0, c: tan(radians), d: 1, e: 0, f: 0)
            case ("skewY", 1): Drawing.Transform(a: 1, b: tan(radians), c: 0, d: 1, e: 0, f: 0)
            default: nil
            }
            guard let step else { break }
            result = result.concatenating(step)
            rest = rest[rest.index(after: close)...]
        }
        guard rest.allSatisfy({ $0.isWhitespace || $0 == "," }) else {
            throw LayoutError("transform: expected matrix(a b c d e f), translate(x y), scale(x y), rotate(angle cx cy), skewX(angle) or skewY(angle)")
        }
        return result
    }

    static func pathData(_ text: String) throws -> [Drawing.Segment] {
        typealias Point = Drawing.Point
        var scanner = NumberScanner(text)
        var segments: [Drawing.Segment] = []
        var current = Point(x: 0, y: 0), start = current
        var cubicControl: Point?, quadControl: Point?
        var command: Character?
        while true {
            if let letter = scanner.letter() {
                command = letter
            } else if scanner.atEnd() {
                break
            } else if command == nil || command == "Z" || command == "z" {
                throw LayoutError("d: expected a command letter such as M, L, C or Z")
            }
            guard let letter = command else { break }
            if segments.isEmpty, letter != "M", letter != "m" { throw LayoutError("d: must start with M") }
            let relative = letter.isLowercase
            let origin = current
            func number() throws -> Double {
                guard let value = scanner.number() else { throw LayoutError("d: \(letter) needs more numbers") }
                return value
            }
            func point() throws -> Point {
                let x = try number(), y = try number()
                return relative ? Point(x: origin.x + x, y: origin.y + y) : Point(x: x, y: y)
            }
            func reflect(_ control: Point?) -> Point {
                control.map { Point(x: 2 * origin.x - $0.x, y: 2 * origin.y - $0.y) } ?? origin
            }
            var nextCubic: Point?, nextQuad: Point?
            switch letter.uppercased() {
            case "M":
                current = try point()
                start = current
                segments.append(.move(current))
                command = relative ? "l" : "L"
            case "L":
                current = try point()
                segments.append(.line(current))
            case "H":
                let x = try number()
                current = Point(x: relative ? origin.x + x : x, y: origin.y)
                segments.append(.line(current))
            case "V":
                let y = try number()
                current = Point(x: origin.x, y: relative ? origin.y + y : y)
                segments.append(.line(current))
            case "C", "S":
                let control1 = letter.uppercased() == "C" ? try point() : reflect(cubicControl)
                let control2 = try point()
                current = try point()
                segments.append(.cubic(current, control1: control1, control2: control2))
                nextCubic = control2
            case "Q", "T":
                let control = letter.uppercased() == "Q" ? try point() : reflect(quadControl)
                current = try point()
                segments.append(.quad(current, control: control))
                nextQuad = control
            case "A":
                let radii = Point(x: try number(), y: try number()), rotation = try number()
                guard let large = scanner.flag(), let sweep = scanner.flag() else { throw LayoutError("d: A needs two flags of 0 or 1") }
                current = try point()
                segments += Drawing.arc(from: origin, to: current, radii: radii, rotation: rotation, large: large, sweep: sweep)
            case "Z":
                segments.append(.close)
                current = start
            default:
                throw LayoutError("d: \(letter) is not a path command; use M, L, H, V, C, S, Q, T, A or Z")
            }
            cubicControl = nextCubic
            quadControl = nextQuad
            guard segments.count <= Drawing.maximumSegments else { throw LayoutError("d has more than \(Drawing.maximumSegments) segments") }
        }
        return segments
    }
}

private struct NumberScanner {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    static func numbers(_ text: String) -> [Double]? {
        var scanner = NumberScanner(text)
        var values: [Double] = []
        while let value = scanner.number() { values.append(value) }
        return scanner.atEnd() ? values : nil
    }

    mutating func atEnd() -> Bool {
        skipSeparators()
        return index == bytes.count
    }

    mutating func letter() -> Character? {
        skipSeparators()
        guard index < bytes.count, (65...90).contains(bytes[index]) || (97...122).contains(bytes[index]) else { return nil }
        defer { index += 1 }
        return Character(Unicode.Scalar(bytes[index]))
    }

    mutating func flag() -> Bool? {
        skipSeparators()
        guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { return nil }
        defer { index += 1 }
        return bytes[index] == UInt8(ascii: "1")
    }

    mutating func number() -> Double? {
        skipSeparators()
        let start = index
        func digits() -> Bool {
            let first = index
            while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            return index > first
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
        var hasDigits = digits()
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            hasDigits = digits() || hasDigits
        }
        guard hasDigits else {
            index = start
            return nil
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            let mark = index
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            if !digits() { index = mark }
        }
        guard let value = Double(String(decoding: bytes[start..<index], as: UTF8.self)), value.isFinite else {
            index = start
            return nil
        }
        return value
    }

    private mutating func skipSeparators() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D, 0x2C].contains(bytes[index]) { index += 1 }
    }
}
