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

    @Test func readsTheSyncAnswerOfAGatewayThatSendsNoTimes() throws {
        let id = UUID()
        let result = try JSONDecoder().decode(SyncResult.self, from: Data(#"{"end": ["\#(id)"]}"#.utf8))
        #expect(result.end == [id])
        #expect(result.activities.isEmpty)
    }

    @Test func widgetReportsNameKnownFamiliesAndBoundTheirPlaces() throws {
        let place = #"{"widget": "\#(UUID())", "family": "systemSmall"}"#
        let report = try JSONDecoder().decode(WidgetReport.self, from: Data(#"{"layoutVersion": "0.12.0", "places": [\#(place)]}"#.utf8))
        #expect(report.pushToken == nil && report.places.map(\.family) == [.systemSmall])
        let unknown = #"{"layoutVersion": "0.12.0", "places": [{"widget": "\#(UUID())", "family": "systemHuge"}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WidgetReport.self, from: Data(unknown.utf8)) }
        let many = #"{"layoutVersion": "0.12.0", "places": [\#(Array(repeating: place, count: WidgetReport.maximumPlaces + 1).joined(separator: ","))]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WidgetReport.self, from: Data(many.utf8)) }
    }

    @Test(arguments: [WidgetSnapshot.Content.layout(.object(["systemSmall": .string("6,400")])), .requires(Version(0, 13, 0))])
    func widgetSnapshotsRoundTripWithAPlainDecoder(content: WidgetSnapshot.Content) throws {
        let snapshot = WidgetSnapshot(id: UUID(), title: "Steps", revision: 3, staleAt: Date(timeIntervalSince1970: 1793000000), content: content)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.content == content && decoded.staleAt == snapshot.staleAt && decoded.revision == 3)
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
