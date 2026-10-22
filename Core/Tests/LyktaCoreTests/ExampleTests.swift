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
}
