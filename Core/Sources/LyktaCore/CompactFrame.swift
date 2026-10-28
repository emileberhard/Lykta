struct CompactFrame: Sendable {
    static let prefix = "~1"
    let hash: UInt64
    let packed: [UInt8]

    init(hash: UInt64, packed: [UInt8]) {
        self.hash = hash
        self.packed = packed
    }

    init?(_ text: String) {
        guard text.hasPrefix(Self.prefix), let bytes = Base92.decode(text.dropFirst(Self.prefix.count)), bytes.count > 8 else { return nil }
        hash = bytes.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
        packed = Array(bytes.dropFirst(8))
    }

    var text: String {
        let header = (0..<8).reversed().map { UInt8(truncatingIfNeeded: hash >> ($0 * 8)) }
        return Self.prefix + Base92.encode(header + packed)
    }
}
