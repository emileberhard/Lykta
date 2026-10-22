import Foundation

public enum Modifier: Decodable, Sendable {
    case padding(Insets)
    case frame(Frame)
    case fixedSize(FixedSize)
    case layoutPriority(Double)
    case offset(x: Double, y: Double)
    case rotation(degrees: Double)
    case scale(Double)
    case opacity(Double)
    case foreground([Paint])
    case background(Paint)
    case tint(Paint)
    case clip(Clip)
    case shadow(Shadow)
    case font(Font)
    case fontWeight(Weight)
    case fontDesign(Design)
    case fontWidth(Width)
    case bold(Bool)
    case italic(Bool)
    case underline(Bool)
    case strikethrough(Bool)
    case monospacedDigit(Bool)
    case tracking(Double)
    case lineLimit(Int)
    case minimumScaleFactor(Double)
    case multilineTextAlignment(Node.Content.HorizontalAlignment)
    case truncationMode(Truncation)
    case textCase(TextCase)
    case contentTransition(ContentTransition)
    case transition(Transition)
    case animation(Animation)
    case id(JSONValue)
    case overlay(Node)
    case blur(Double)
    case grayscale(Double)
    case saturation(Double)
    case brightness(Double)
    case symbolRenderingMode(SymbolRendering)
    case imageScale(ImageScale)
    case accessibilityLabel(String)

    public enum FixedSize: Sendable { case both, horizontal, vertical }
    public enum Weight: String, Choice { case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black }
    public enum Design: String, Choice { case `default`, serif, rounded, monospaced }
    public enum Width: String, Choice { case compressed, condensed, standard, expanded }
    public enum Truncation: String, Choice { case head, middle, tail }
    public enum TextCase: String, Choice { case uppercase, lowercase }
    public enum SymbolRendering: String, Choice { case monochrome, hierarchical, palette, multicolor }
    public enum ImageScale: String, Choice { case small, medium, large }

    public enum ContentTransition: Decodable, Sendable {
        public enum Name: String, Choice { case numericText, opacity, interpolate, identity, symbolReplace }

        case named(Name)
        case numericText(value: Double)

        public init(from decoder: any Decoder) throws {
            if (try? decoder.singleValueContainer().decode(String.self)) != nil {
                self = .named(try Name(from: decoder))
            } else {
                let fields = try decoder.container(keyedBy: Key.self)
                try fields.allowOnly(["numericText"])
                self = .numericText(value: try fields.required("numericText"))
            }
        }
    }

    public indirect enum Transition: Decodable, Sendable {
        public enum Name: String, Choice { case opacity, slide, scale, identity }
        public enum Edge: String, Choice { case top, bottom, leading, trailing }

        case named(Name)
        case move(Edge)
        case push(Edge)
        case combined([Transition])

        public init(from decoder: any Decoder) throws {
            if (try? decoder.singleValueContainer().decode(String.self)) != nil {
                self = .named(try Name(from: decoder))
            } else if var list = try? decoder.unkeyedContainer() {
                var parts: [Transition] = []
                while !list.isAtEnd {
                    let part = try list.decode(Transition.self)
                    if case .combined = part { throw DecodingError.dataCorruptedError(in: list, debugDescription: "lists do not nest") }
                    parts.append(part)
                }
                guard (2...3).contains(parts.count) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "combine 2 or 3 transitions"))
                }
                self = .combined(parts)
            } else {
                let fields = try decoder.container(keyedBy: Key.self)
                try fields.allowOnly(["move", "push"])
                guard fields.allKeys.count == 1, let key = fields.allKeys.first?.stringValue else {
                    throw fields.invalid(#"expected {"move": edge} or {"push": edge}"#)
                }
                let edge: Edge = try fields.required(key)
                self = key == "move" ? .move(edge) : .push(edge)
            }
        }
    }

    public struct Animation: Decodable, Sendable {
        public enum Curve: String, Choice { case `default`, linear, easeIn, easeOut, easeInOut, spring, bouncy, snappy, smooth }

        public let curve: Curve
        public let duration: Double?
        public let delay: Double
        public let trigger: JSONValue

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            try fields.allowOnly(["curve", "duration", "delay", "value"])
            curve = try fields.optional("curve") ?? .default
            duration = fields.contains(Key(stringValue: "duration")) ? try fields.number("duration", in: 0.05...2) : nil
            delay = fields.contains(Key(stringValue: "delay")) ? try fields.number("delay", in: 0...1) : 0
            trigger = try fields.required("value")
        }
    }

    public enum Font: Decodable, Sendable {
        public enum Style: String, Choice {
            case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
        }

        case style(Style)
        case size(Double)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let size = try? container.decode(Double.self) {
                guard (1...160).contains(size) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "font size must be between 1 and 160") }
                self = .size(size)
            } else {
                self = .style(try container.decode(Style.self))
            }
        }
    }

    public enum Clip: Decodable, Sendable {
        case shape(Node.Content.Shape.Kind)
        case cornerRadius(Double)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = if let radius = try? container.decode(Double.self) { .cornerRadius(radius) } else { .shape(try container.decode(Node.Content.Shape.Kind.self)) }
        }
    }

    public struct Insets: Decodable, Sendable {
        public let top, leading, bottom, trailing: Double

        public init(from decoder: any Decoder) throws {
            if let all = try? decoder.singleValueContainer().decode(Double.self) {
                (top, leading, bottom, trailing) = (all, all, all, all)
                return
            }
            let fields = try decoder.container(keyedBy: Key.self)
            try fields.allowOnly(["top", "leading", "bottom", "trailing", "horizontal", "vertical"])
            let horizontal: Double? = try fields.optional("horizontal")
            let vertical: Double? = try fields.optional("vertical")
            top = try fields.optional("top") ?? vertical ?? 0
            bottom = try fields.optional("bottom") ?? vertical ?? 0
            leading = try fields.optional("leading") ?? horizontal ?? 0
            trailing = try fields.optional("trailing") ?? horizontal ?? 0
        }
    }

    public struct Frame: Decodable, Sendable {
        public let width, height, minWidth, maxWidth, minHeight, maxHeight: Double?
        public let alignment: Node.Content.Alignment

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            try fields.allowOnly(["width", "height", "minWidth", "maxWidth", "minHeight", "maxHeight", "alignment"])
            func length(_ key: String) throws -> Double? {
                if (try? fields.optional(key) as String?) == "infinity" { return .infinity }
                guard let value: Double = try fields.optional(key) else { return nil }
                guard value >= 0 else { throw fields.invalid("must not be negative", at: key) }
                return value
            }
            width = try length("width")
            height = try length("height")
            minWidth = try length("minWidth")
            maxWidth = try length("maxWidth")
            minHeight = try length("minHeight")
            maxHeight = try length("maxHeight")
            alignment = try fields.optional("alignment") ?? .center
        }
    }

    public struct Shadow: Decodable, Sendable {
        public let color: ColorValue
        public let radius, x, y: Double

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: Key.self)
            try fields.allowOnly(["color", "radius", "x", "y"])
            color = try fields.optional("color") ?? .rgb(red: 0, green: 0, blue: 0, opacity: 0.33)
            radius = try fields.optional("radius") ?? 4
            x = try fields.optional("x") ?? 0
            y = try fields.optional("y") ?? 0
        }
    }

    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        guard fields.allKeys.count == 1, let name = fields.allKeys.first?.stringValue else {
            throw fields.invalid("a modifier is an object with exactly one key, such as {\"padding\": 8}")
        }
        func value<T: Decodable>() throws -> T { try fields.required(name) }
        switch name {
        case "padding": self = .padding(try value())
        case "frame": self = .frame(try value())
        case "fixedSize":
            if let axis = try? value() as Node.Content.Axis { self = .fixedSize(axis == .horizontal ? .horizontal : .vertical) }
            else if try value() as Bool { self = .fixedSize(.both) }
            else { throw fields.invalid("expected true, \"horizontal\" or \"vertical\"", at: name) }
        case "layoutPriority": self = .layoutPriority(try value())
        case "offset":
            let offset: [Double] = try value()
            guard offset.count == 2 else { throw fields.invalid("expected [x, y]", at: name) }
            self = .offset(x: offset[0], y: offset[1])
        case "rotation": self = .rotation(degrees: try value())
        case "scale": self = .scale(try fields.number(name, in: 0...10))
        case "opacity": self = .opacity(try fields.number(name, in: 0...1))
        case "foreground":
            let paints: [Paint] = if let paint = try? value() as Paint { [paint] } else { try value() }
            guard (1...3).contains(paints.count) else { throw fields.invalid("expected a paint or a palette of 2 or 3 paints", at: name) }
            self = .foreground(paints)
        case "background": self = .background(try value())
        case "tint": self = .tint(try value())
        case "clip": self = .clip(try value())
        case "shadow": self = .shadow(try value())
        case "font": self = .font(try value())
        case "fontWeight": self = .fontWeight(try value())
        case "fontDesign": self = .fontDesign(try value())
        case "fontWidth": self = .fontWidth(try value())
        case "bold": self = .bold(try value())
        case "italic": self = .italic(try value())
        case "underline": self = .underline(try value())
        case "strikethrough": self = .strikethrough(try value())
        case "monospacedDigit": self = .monospacedDigit(try value())
        case "tracking": self = .tracking(try fields.number(name, in: -20...20))
        case "lineLimit": self = .lineLimit(Int(try fields.number(name, in: 1...20)))
        case "minimumScaleFactor": self = .minimumScaleFactor(try fields.number(name, in: 0.1...1))
        case "multilineTextAlignment": self = .multilineTextAlignment(try value())
        case "truncationMode": self = .truncationMode(try value())
        case "textCase": self = .textCase(try value())
        case "contentTransition": self = .contentTransition(try value())
        case "transition": self = .transition(try value())
        case "animation": self = .animation(try value())
        case "id":
            let id: JSONValue = try value()
            switch id {
            case .string, .number, .bool: self = .id(id)
            case .array, .object, .null: throw fields.invalid("expected a string, number or boolean", at: name)
            }
        case "overlay": self = .overlay(try value())
        case "blur": self = .blur(try fields.number(name, in: 0...20))
        case "grayscale": self = .grayscale(try fields.number(name, in: 0...1))
        case "saturation": self = .saturation(try fields.number(name, in: 0...5))
        case "brightness": self = .brightness(try fields.number(name, in: -1...1))
        case "symbolRenderingMode": self = .symbolRenderingMode(try value())
        case "imageScale": self = .imageScale(try value())
        case "accessibilityLabel": self = .accessibilityLabel(try value())
        default: throw fields.invalid("unknown modifier", at: name)
        }
    }

    public var isTextModifier: Bool {
        switch self {
        case .font, .fontWeight, .fontDesign, .fontWidth, .bold, .italic, .underline, .strikethrough, .monospacedDigit,
             .tracking:
            true
        case let .foreground(paints): paints.count == 1
        default: false
        }
    }
}

public enum Paint: Decodable, Sendable {
    public enum Level: String, Choice { case primary, secondary, tertiary, quaternary }
    public enum Direction: String, Choice { case vertical, horizontal, diagonal, radial, angular }

    case color(ColorValue)
    case level(Level)
    case gradient([ColorValue], Direction)

    public init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self = if let level = Level(rawValue: name) { .level(level) } else { .color(try ColorValue(from: decoder)) }
            return
        }
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(["gradient", "direction"])
        let colors: [ColorValue] = try fields.required("gradient")
        guard (2...8).contains(colors.count) else { throw fields.invalid("expected 2 to 8 colors", at: "gradient") }
        self = .gradient(colors, try fields.optional("direction") ?? .vertical)
    }
}

public enum ColorValue: Decodable, Sendable {
    public enum Name: String, Choice {
        case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, white, gray, black, clear, accent
    }

    case named(Name)
    case rgb(red: Double, green: Double, blue: Double, opacity: Double)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let color = ColorValue(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected \(Self.forms)")
        }
        self = color
    }

    static var forms: String {
        "#RGB, #RRGGBB, #RRGGBBAA, rgb(r, g, b), rgba(r, g, b, a) or one of \(Name.allCases.map(\.rawValue).joined(separator: ", "))"
    }

    init?(_ text: String) {
        if let name = Name(rawValue: text) {
            self = .named(name)
        } else if text.first == "#" {
            let hex = text.dropFirst()
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy(\.isHexDigit) else { return nil }
            let digits = hex.count > 4 ? Array(hex) : hex.flatMap { [$0, $0] }
            let channels = stride(from: 0, to: digits.count, by: 2).map { Double(Int(String(digits[$0...$0 + 1]), radix: 16)!) / 255 }
            self = .rgb(red: channels[0], green: channels[1], blue: channels[2], opacity: channels.count == 4 ? channels[3] : 1)
        } else if let open = text.firstIndex(of: "("), text.last == ")", ["rgb", "rgba"].contains(text[..<open]) {
            let parts = text[open...].dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let channels = parts.enumerated().compactMap { index, part in
                part.hasSuffix("%") ? Double(part.dropLast()).map { $0 / 100 } : Double(part).map { index < 3 ? $0 / 255 : $0 }
            }
            guard (3...4).contains(parts.count), channels.count == parts.count, channels.allSatisfy((0...1).contains) else { return nil }
            self = .rgb(red: channels[0], green: channels[1], blue: channels[2], opacity: channels.count == 4 ? channels[3] : 1)
        } else {
            return nil
        }
    }
}
