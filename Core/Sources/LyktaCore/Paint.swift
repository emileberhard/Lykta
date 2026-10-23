import Foundation

public enum Paint: Decodable, Sendable {
    public enum Level: String, Choice { case primary, secondary, tertiary, quaternary }
    public enum Direction: String, Choice { case vertical, horizontal, diagonal, radial, angular }

    case color(ColorValue)
    case level(Level)
    case gradient([ColorValue], Direction)

    public init(from decoder: any Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            if let level = Level(rawValue: name) {
                Level.record(level, at: decoder.codingPath)
                self = .level(level)
            } else {
                self = .color(try ColorValue(from: decoder))
            }
            return
        }
        let fields = try decoder.container(keyedBy: Key.self)
        try fields.allowOnly(["gradient", "direction"])
        fields.recordKeys(in: "paint")
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
        let text = try container.decode(String.self)
        guard let color = ColorValue(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected \(Self.forms)")
        }
        if case let .named(name) = color {
            Name.record(name, at: container.codingPath)
        } else if text.hasPrefix("rgb") {
            FeatureLog.record("color.rgb", at: container.codingPath)
        } else if text.hasPrefix("#"), text.count <= 5 {
            FeatureLog.record("color.shortHex", at: container.codingPath)
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
            guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
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
