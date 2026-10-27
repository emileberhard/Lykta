import Foundation
import LyktaCore

nonisolated struct WidgetExample: Identifiable, Sendable {
    struct Route: Hashable {
        let id: String
    }

    static let widgetName = "example"

    let id: String
    let title: String
    let layout: WidgetLayout
    private let fields: [String: JSONValue]

    var route: Route { Route(id: id) }

    @concurrent static func bundled(at date: Date) async -> [WidgetExample] {
        guard let folder = Bundle.main.url(forResource: "examples", withExtension: nil)?.appending(path: "widgets"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            preconditionFailure("The app bundles the skill's examples folder")
        }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
            do {
                return try WidgetExample(file: file, at: date)
            } catch {
                preconditionFailure("examples/widgets/\(file.lastPathComponent): \(error)")
            }
        }
    }

    private init(file: URL, at date: Date) throws {
        guard case let .object(fields) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)),
              case let .string(title) = fields["title"], let layout = fields["layout"] else {
            throw LayoutError("expected a PUT body with a title and a layout")
        }
        id = file.deletingPathExtension().lastPathComponent
        self.title = title
        self.fields = fields
        self.layout = try WidgetLayout(json: layout.filled(with: Self.data(fields["data"], at: date), for: .widget).json)
    }

    func request(at date: Date) -> JSONValue {
        .object(fields.merging(["data": Self.data(fields["data"], at: date)]) { $1 })
    }

    private static func data(_ data: JSONValue?, at date: Date) -> JSONValue {
        (data ?? .object([:])).movingExampleTimes(to: date)
    }
}
