import Foundation
import LyktaCore
import Testing

struct ExampleTests {
    @Test func movesExampleTimesToTheGivenDate() {
        let data = JSONValue.object([
            "start": .number(1_793_000_000), "end": .number(1_793_000_600),
            "steps": .array([.object(["at": .number(1_792_999_000)]), .number(42)]),
            "later": .number(1_793_200_000), "year": .number(2026), "name": .string("1793000000"),
        ])
        #expect(data.movingExampleTimes(to: Date(timeIntervalSince1970: 1_800_000_000.4)) == .object([
            "start": .number(1_800_000_000), "end": .number(1_800_000_600),
            "steps": .array([.object(["at": .number(1_799_999_000)]), .number(42)]),
            "later": .number(1_793_200_000), "year": .number(2026), "name": .string("1793000000"),
        ]))
    }

    @Test func examplesSurviveTheWire() throws {
        struct Body: Decodable {
            let title: String
            let layout: JSONValue
            let data: JSONValue
        }
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../Gateway/Sources/LyktaGateway/Skill/examples")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        #expect(!files.isEmpty)
        for file in files {
            let body = try JSONDecoder().decode(Body.self, from: Data(contentsOf: file))
            let state = try LyktaActivity.ContentState(title: body.title, layout: body.layout.filled(with: body.data.movingExampleTimes(to: .now)).json)
            let decoded = try JSONDecoder().decode(LyktaActivity.ContentState.self, from: JSONEncoder().encode(state))
            #expect(decoded == state, "\(file.lastPathComponent)")
            #expect(decoded.layout != nil, "\(file.lastPathComponent)")
        }
    }
}
