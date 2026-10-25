enum Base92 {
    private static let alphabet = Array((UInt8(32)...UInt8(126)).filter { !Array(#""/\"#.utf8).contains($0) })
    private static let values = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, $0.offset) })
    private static let radix = alphabet.count
    private static let wide = radix * radix - 8193

    static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        for byte in bytes {
            buffer |= Int(byte) << bits
            bits += 8
            if bits > 13 {
                var value = buffer & 8191
                if value > wide {
                    buffer >>= 13
                    bits -= 13
                } else {
                    value = buffer & 16383
                    buffer >>= 14
                    bits -= 14
                }
                output += [alphabet[value % radix], alphabet[value / radix]]
            }
        }
        if bits > 0 {
            output.append(alphabet[buffer % radix])
            if bits > 7 || buffer >= radix { output.append(alphabet[buffer / radix]) }
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func decode(_ text: Substring) -> [UInt8]? {
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        var pending: Int?
        for character in text.utf8 {
            guard let value = values[character] else { return nil }
            guard let first = pending else {
                pending = value
                continue
            }
            let pair = first + value * radix
            buffer |= pair << bits
            bits += pair & 8191 > wide ? 13 : 14
            while bits >= 8 {
                output.append(UInt8(buffer & 255))
                buffer >>= 8
                bits -= 8
            }
            pending = nil
        }
        if let pending { output.append(UInt8((buffer | pending << bits) & 255)) }
        return encode(output) == text ? output : nil
    }
}
