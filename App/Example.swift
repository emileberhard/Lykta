import Foundation
import LyktaCore

nonisolated struct Example: Identifiable, Sendable {
    static let activityName = "example"
    private static let fixtureTime = 1_793_000_000.0
    private static let fixtureSpan = 172_800.0

    let id: String
    let title: String
    let preview: LyktaActivity.ContentState
    private let fields: [String: JSONValue]

    @concurrent static func bundled(at date: Date) async -> [Example] {
        guard let folder = Bundle.main.url(forResource: "examples", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            preconditionFailure("The app bundles the skill's examples folder")
        }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
            do {
                return try Example(file: file, at: date)
            } catch {
                preconditionFailure("examples/\(file.lastPathComponent): \(error)")
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
        preview = try LyktaActivity.ContentState(title: title, layout: layout.filled(with: Self.data(fields["data"], at: date)).json)
    }

    func request(at date: Date) -> JSONValue {
        .object(fields.merging(["data": Self.data(fields["data"], at: date)]) { $1 })
    }

    private static func data(_ data: JSONValue?, at date: Date) -> JSONValue {
        moved(data ?? .object([:]), by: (date.timeIntervalSince1970 - fixtureTime).rounded())
    }

    private static func moved(_ value: JSONValue, by shift: Double) -> JSONValue {
        switch value {
        case let .number(number) where abs(number - fixtureTime) < fixtureSpan: .number(number + shift)
        case let .object(fields): .object(fields.mapValues { moved($0, by: shift) })
        case let .array(items): .array(items.map { moved($0, by: shift) })
        case .number, .string, .bool, .null: value
        }
    }
}
