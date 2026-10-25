import Foundation
#if os(iOS)
import ActivityKit
#endif

public struct LyktaActivity: Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public static let compactSince = Version(0, 8, 0)
        private static let compactPrefix = "~1"

        private enum Form: Hashable, Sendable {
            case legacy, compact
        }

        public let title: String
        public let layout: Layout?
        private let packed: Data
        private let form: Form
        private let hash: UInt64

        public init(title: String, layout json: [UInt8]) throws(LayoutError) {
            self.title = title
            layout = try Layout(json: json)
            packed = Data(try Deflate.compress(json))
            form = .legacy
            hash = fnv1a(Array(title.utf8) + [0] + Array(packed))
        }

        private init(title: String, layout: Layout?, packed: Data, form: Form, hash: UInt64) {
            self.title = title
            self.layout = layout
            self.packed = packed
            self.form = form
            self.hash = hash
        }

        public var fingerprint: String {
            String(hash, radix: 16)
        }

        public static func isCompact(for layoutVersion: Version?) -> Bool {
            layoutVersion.map { $0 >= compactSince } ?? false
        }

        public static func compressedByteCount(of layout: [UInt8], for layoutVersion: Version?) throws(LayoutError) -> Int {
            try Deflate.compress(layout, dictionary: isCompact(for: layoutVersion) ? WireDictionary.v1 : []).count
        }

        public func encoded(for layoutVersion: Version?) throws(LayoutError) -> Self {
            guard form == .legacy, Self.isCompact(for: layoutVersion) else { return self }
            guard let json = Deflate.decompress(Array(packed), limit: Layout.maximumBytes) else {
                throw LayoutError("the stored layout cannot be decompressed")
            }
            return Self(title: title, layout: layout, packed: Data(try Deflate.compress(json, dictionary: WireDictionary.v1)), form: .compact, hash: hash)
        }

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            title = try fields.decode(String.self, forKey: .title)
            if let text = try? fields.decode(String.self, forKey: .layout), text.hasPrefix(Self.compactPrefix) {
                guard let bytes = Base92.decode(text.dropFirst(Self.compactPrefix.count)), bytes.count > 8 else {
                    throw DecodingError.dataCorruptedError(forKey: .layout, in: fields, debugDescription: "invalid compact layout")
                }
                packed = Data(bytes.dropFirst(8))
                form = .compact
                hash = bytes.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
            } else {
                packed = try fields.decode(Data.self, forKey: .layout)
                form = .legacy
                hash = fnv1a(Array(title.utf8) + [0] + Array(packed))
            }
            let dictionary = form == .compact ? WireDictionary.v1 : []
            layout = Deflate.decompress(Array(packed), limit: Layout.maximumBytes, dictionary: dictionary).flatMap { try? Layout(json: $0) }
        }

        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(title, forKey: .title)
            switch form {
            case .legacy:
                try fields.encode(packed, forKey: .layout)
            case .compact:
                let header = (0..<8).reversed().map { UInt8(truncatingIfNeeded: hash >> ($0 * 8)) }
                try fields.encode(Self.compactPrefix + Base92.encode(header + Array(packed)), forKey: .layout)
            }
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title && lhs.packed == rhs.packed && lhs.form == rhs.form && lhs.hash == rhs.hash
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(packed)
            hasher.combine(form)
            hasher.combine(hash)
        }

        private enum CodingKeys: String, CodingKey {
            case title, layout
        }
    }
}

#if os(iOS)
extension LyktaActivity: ActivityAttributes {}
#endif
