struct MarkupElement: Sendable {
    let name: String
    let attributes: [String: String]
    let children: [MarkupElement]
    let text: String
}

struct MarkupReader {
    static let maximumElements = 1024
    static let maximumDepth = 32

    private let bytes: [UInt8]
    private var index = 0
    private var elements = 0

    private init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func document(_ text: String) throws(LayoutError) -> MarkupElement {
        var reader = MarkupReader(Array(text.utf8))
        try reader.skipProlog()
        guard reader.starts("<") else { throw LayoutError("expected markup starting with <svg") }
        let root = try reader.element(depth: 1)
        try reader.skipProlog()
        guard reader.index == reader.bytes.count else { throw LayoutError("unexpected content after </\(root.name)>") }
        return root
    }

    private mutating func skipProlog() throws(LayoutError) {
        while true {
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            if starts("<?") { try skip(past: "?>") } else if starts("<!--") { try skip(past: "-->") } else if starts("<!DOCTYPE") { try skip(past: ">") } else { return }
        }
    }

    private mutating func element(depth: Int) throws(LayoutError) -> MarkupElement {
        elements += 1
        guard depth <= Self.maximumDepth else { throw LayoutError("elements nest deeper than \(Self.maximumDepth) levels") }
        guard elements <= Self.maximumElements else { throw LayoutError("markup has more than \(Self.maximumElements) elements") }
        index += 1
        let name = self.name()
        guard !name.isEmpty else { throw LayoutError("expected an element name after <") }
        var attributes: [String: String] = [:]
        while true {
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            if starts("/>") {
                index += 2
                return MarkupElement(name: name, attributes: attributes, children: [], text: "")
            }
            if starts(">") {
                index += 1
                break
            }
            let key = self.name()
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            guard !key.isEmpty, starts("=") else { throw LayoutError("<\(name)>: expected attribute=\"value\", > or />") }
            index += 1
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, [UInt8(ascii: "\""), UInt8(ascii: "'")].contains(bytes[index]),
                  let end = bytes[(index + 1)...].firstIndex(of: bytes[index]) else {
                throw LayoutError("<\(name)> \(key): expected a quoted value")
            }
            let value = try Self.decode(bytes[(index + 1)..<end])
            index = end + 1
            guard attributes.updateValue(value, forKey: key) == nil else { throw LayoutError("<\(name)> repeats \(key)") }
        }
        var children: [MarkupElement] = []
        var text = ""
        while true {
            guard index < bytes.count else { throw LayoutError("<\(name)> is never closed") }
            if starts("</") {
                index += 2
                let closing = self.name()
                while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
                guard closing == name, starts(">") else { throw LayoutError("expected </\(name)>") }
                index += 1
                return MarkupElement(name: name, attributes: attributes, children: children, text: text)
            } else if starts("<![CDATA[") {
                index += 9
                let start = index
                try skip(past: "]]>")
                text += String(decoding: bytes[start..<(index - 3)], as: UTF8.self)
            } else if starts("<!--") {
                try skip(past: "-->")
            } else if starts("<") {
                children.append(try element(depth: depth + 1))
            } else {
                let end = bytes[index...].firstIndex(of: UInt8(ascii: "<")) ?? bytes.count
                text += try Self.decode(bytes[index..<end])
                index = end
            }
        }
    }

    private mutating func name() -> String {
        let start = index
        while index < bytes.count, !Self.isSpace(bytes[index]), !"=/<>\"'".utf8.contains(bytes[index]) { index += 1 }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private func starts(_ prefix: String) -> Bool {
        bytes[index...].starts(with: prefix.utf8)
    }

    private mutating func skip(past terminator: String) throws(LayoutError) {
        let pattern = Array(terminator.utf8)
        while index < bytes.count {
            if bytes[index...].starts(with: pattern) {
                index += pattern.count
                return
            }
            index += 1
        }
        throw LayoutError("expected \(terminator) before the end of the markup")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func decode(_ bytes: ArraySlice<UInt8>) throws(LayoutError) -> String {
        let raw = String(decoding: bytes, as: UTF8.self)
        guard raw.contains("&") else { return raw }
        var output = ""
        var rest = raw[...]
        while let ampersand = rest.firstIndex(of: "&") {
            output += rest[..<ampersand]
            guard let semicolon = rest[ampersand...].firstIndex(of: ";") else { throw LayoutError("an & must start an entity such as &amp;") }
            let entity = rest[rest.index(after: ampersand)..<semicolon]
            let scalar: Unicode.Scalar? = switch entity {
            case "amp": "&"
            case "lt": "<"
            case "gt": ">"
            case "quot": "\""
            case "apos": "'"
            default:
                if entity.hasPrefix("#x") { UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init) }
                else if entity.hasPrefix("#") { UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init) }
                else { nil }
            }
            guard let scalar else { throw LayoutError("unknown entity &\(entity);") }
            output.unicodeScalars.append(scalar)
            rest = rest[rest.index(after: semicolon)...]
        }
        return output + rest
    }
}
