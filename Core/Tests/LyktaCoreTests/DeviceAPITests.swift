import Foundation
import Testing
import LyktaCore

struct DeviceAPITests {
    @Test(arguments: [
        ("pushToStartToken", JSONValue.string("ABCDEF"), "pushToStartToken: expected lowercase hex"),
        ("pushToStartToken", .string("abc"), "pushToStartToken: expected lowercase hex"),
        ("appVersion", .string(String(repeating: "9", count: 33)), "appVersion: must be at most 32 characters"),
        ("bundleInstance", .string("one"), "bundleInstance: "),
        ("activities", .array([.object(["id": .string(UUID().uuidString), "state": .string("gone")])]), #"activities[0].state: "gone" is not one of"#),
    ])
    func rejectsMalformedReports(key: String, value: JSONValue, message: String) {
        var fields: [String: JSONValue] = [
            "pushToStartToken": .string("abcdef"), "appVersion": .string("1.0 (1)"),
            "bundleInstance": .string(UUID().uuidString), "activities": .array([]),
        ]
        fields[key] = value
        do {
            _ = try decode(fields)
            Issue.record("accepted \(key): \(value)")
        } catch {
            #expect(error.description.hasPrefix(message), "\(error)")
        }
    }

    @Test func actionsAreAButtonOrAToggle() throws {
        let toggle = Action(id: UUID(), activity: UUID(), input: .toggle("items.0.done", isOn: true))
        #expect(try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(toggle)) == toggle)
        let mixed = #"{"id": "\#(UUID())", "activity": "\#(UUID())", "button": "retry", "isOn": true}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Action.self, from: Data(mixed.utf8)) }
    }

    private func decode(_ fields: [String: JSONValue]) throws(LayoutError) -> DeviceReport {
        do {
            return try JSONDecoder().decode(DeviceReport.self, from: Data(JSONValue.object(fields).json))
        } catch let error as DecodingError {
            throw LayoutError(error)
        } catch {
            throw LayoutError("\(error)")
        }
    }
}
