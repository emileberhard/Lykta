#if DEBUG
import Foundation
import LyktaCore
import SwiftUI
import WidgetKit

private enum Staged {
    private static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../.local/render")
    private static let anchor = 1_793_000_000.0
    static let attributes = LyktaActivity(id: UUID(), name: "render")

    private struct Input: Decodable {
        let title: String
        let layout: JSONValue
        let data: JSONValue
    }

    static var states: [LyktaActivity.ContentState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map(state)
    }

    private static func state(_ url: URL) -> LyktaActivity.ContentState {
        let report = url.deletingPathExtension().appendingPathExtension("error")
        do {
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: url))
            let data = rebased(input.data, by: Date.now.timeIntervalSince1970 - anchor)
            let state = try LyktaActivity.ContentState(title: input.title, layout: input.layout.filled(with: data).json)
            try? FileManager.default.removeItem(at: report)
            return state
        } catch {
            try? Data("\(error)".utf8).write(to: report)
            let message = String(decoding: try! JSONEncoder().encode("\(error)"), as: UTF8.self)
            let warning = #"{"symbol": "exclamationmark.triangle.fill", "modifiers": [{"foreground": "red"}]}"#
            let layout = #"{"lockScreen": {"text": \#(message), "modifiers": [{"foreground": "red"}, {"padding": 16}]}, "#
                + #""compactLeading": \#(warning), "compactTrailing": "Error", "minimal": \#(warning)}"#
            return try! LyktaActivity.ContentState(title: "Error", layout: Array(layout.utf8))
        }
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

#Preview("Staged", as: .content, using: Staged.attributes) {
    LyktaLiveActivity()
} contentStates: {
    for state in Staged.states { state }
}
#endif
