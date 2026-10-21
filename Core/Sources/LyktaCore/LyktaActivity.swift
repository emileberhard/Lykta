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
        public let title: String
        public let layout: Layout?
        private let packed: Data

        public init(title: String, layout json: [UInt8]) throws(LayoutError) {
            self.title = title
            layout = try Layout(json: json)
            do {
                packed = Data(try Deflate.compress(json))
            } catch {
                throw LayoutError("compression failed: \(error)")
            }
        }

        public var fingerprint: String {
            LyktaCore.fingerprint(Array(title.utf8) + [0] + Array(packed))
        }

        public init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            title = try fields.decode(String.self, forKey: .title)
            packed = try fields.decode(Data.self, forKey: .layout)
            layout = try? Layout(json: Deflate.decompress(Array(packed), limit: Layout.maximumBytes))
        }

        public func encode(to encoder: any Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(title, forKey: .title)
            try fields.encode(packed, forKey: .layout)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.title == rhs.title && lhs.packed == rhs.packed
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(title)
            hasher.combine(packed)
        }

        private enum CodingKeys: String, CodingKey {
            case title, layout
        }
    }
}

#if os(iOS)
extension LyktaActivity: ActivityAttributes {}
#endif
