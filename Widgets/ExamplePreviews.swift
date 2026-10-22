#if DEBUG
import Foundation
import LyktaCore
import SwiftUI
import WidgetKit

private enum Example {
    private static let directory = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../Gateway/Sources/LyktaGateway/Skill/examples")
    static let names = try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .map { $0.deletingPathExtension().lastPathComponent }
        .sorted()
    static let attributes = LyktaActivity(id: UUID(), name: "example")
    private static let anchor = 1_793_000_000.0

    private struct Body: Decodable {
        let title: String
        let layout: JSONValue
        let data: JSONValue?
    }

    static func state(_ name: String) -> LyktaActivity.ContentState {
        let url = directory.appending(path: "\(name).json")
        let body = try! JSONDecoder().decode(Body.self, from: Data(contentsOf: url))
        let data = rebased(body.data ?? .object([:]), by: Date.now.timeIntervalSince1970 - anchor)
        return try! LyktaActivity.ContentState(title: body.title, layout: body.layout.filled(with: data).json)
    }

    private static func rebased(_ value: JSONValue, by shift: Double) -> JSONValue {
        switch value {
        case let .number(number) where abs(number - anchor) < 172_800: .number(number + shift)
        case let .object(fields): .object(fields.mapValues { rebased($0, by: shift) })
        case let .array(items): .array(items.map { rebased($0, by: shift) })
        case .number, .string, .bool, .null: value
        }
    }
}

#Preview("Examples", as: .content, using: Example.attributes) {
    LyktaLiveActivity()
} contentStates: {
    for name in Example.names { Example.state(name) }
}

#Preview("Examples expanded", as: .dynamicIsland(.expanded), using: Example.attributes) {
    LyktaLiveActivity()
} contentStates: {
    for name in Example.names { Example.state(name) }
}

#Preview("Examples compact", as: .dynamicIsland(.compact), using: Example.attributes) {
    LyktaLiveActivity()
} contentStates: {
    for name in Example.names { Example.state(name) }
}

#Preview("Examples minimal", as: .dynamicIsland(.minimal), using: Example.attributes) {
    LyktaLiveActivity()
} contentStates: {
    for name in Example.names { Example.state(name) }
}
#endif
