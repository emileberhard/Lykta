#if DEBUG
import Foundation
import LyktaCore
import SwiftUI
import WidgetKit

private enum Staged {
    private static let directory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../.local/render")
    static let attributes = LyktaActivity(id: UUID(), name: "render")

    private struct Input: Decodable {
        let title: String
        let layout: JSONValue
        let data: JSONValue
    }

    static var states: [LyktaActivity.ContentState] {
        inputs("activity").map { url in
            do {
                let (title, layout) = try load(url, for: .activity)
                return try LyktaActivity.ContentState(title: title, layout: layout)
            } catch {
                let warning = #"{"symbol": "exclamationmark.triangle.fill", "modifiers": [{"foreground": "red"}]}"#
                let layout = #"{"lockScreen": \#(report(error, for: url)), "compactLeading": \#(warning), "compactTrailing": "Error", "minimal": \#(warning)}"#
                return try! LyktaActivity.ContentState(title: "Error", layout: Array(layout.utf8))
            }
        }
    }

    static var widgets: [WidgetEntry] {
        inputs("widget").map { url in
            let layout: WidgetLayout
            do {
                layout = try WidgetLayout(json: load(url, for: .widget).layout)
            } catch {
                layout = try! WidgetLayout(json: Array(#"{"systemSmall": \#(report(error, for: url))}"#.utf8))
            }
            return WidgetEntry(date: .now, state: .content(layout, .systemSmall, isStale: false))
        }
    }

    private static func inputs(_ kind: String) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("\(kind)-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func load(_ url: URL, for surface: Surface) throws -> (title: String, layout: [UInt8]) {
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: url))
        let layout = try input.layout.filled(with: input.data.movingExampleTimes(to: .now), for: surface).json
        try? FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("error"))
        return (input.title, layout)
    }

    private static func report(_ error: any Error, for url: URL) -> String {
        try? Data("\(error)".utf8).write(to: url.deletingPathExtension().appendingPathExtension("error"))
        let message = String(decoding: try! JSONEncoder().encode("\(error)"), as: UTF8.self)
        return #"{"text": \#(message), "modifiers": [{"foreground": "red"}, {"padding": 16}]}"#
    }
}

#Preview("Staged", as: .content, using: Staged.attributes) {
    LyktaLiveActivity()
} contentStates: {
    for state in Staged.states { state }
}

#Preview("Staged widgets", as: .systemSmall) {
    LyktaWidget()
} timeline: {
    for entry in Staged.widgets { entry }
}
#endif
