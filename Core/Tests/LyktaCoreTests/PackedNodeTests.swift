import Foundation
import Testing
@testable import LyktaCore

struct PackedNodeTests {
    @Test func aDrawingRoundTripsWithItsFingerprintAndVersion() throws {
        let value = try json(#"{"text":"ET","modifiers":[{"padding":8},{"background":"blue"}]}"#)
        let admitted = try PackedNode.admitting(value)
        #expect(admitted.requirement == .init(version: Version(0, 17, 0), feature: "notification.avatar.node", path: "sender.avatar"))
        let encoded = try JSONEncoder().encode(admitted.drawing)
        #expect(try JSONDecoder().decode(String.self, from: encoded).hasPrefix("~1"))
        let received = try JSONDecoder().decode(PackedNode.self, from: encoded)
        #expect(try JSONEncoder().encode(received) == encoded)
        #expect(received.compressedBytes == admitted.drawing.compressedBytes)
        guard case .text("ET") = try received.node().content else {
            Issue.record("Expected the admitted text")
            return
        }
    }

    @Test func inflationStopsAtTheLayoutBudget() throws {
        let value = JSONValue.string(String(repeating: "A", count: Layout.maximumBytes + 1))
        let drawing = try PackedNode(packing: value)
        #expect(throws: PackedNode.Failure.inflate) { try drawing.node() }
    }

    @Test(arguments: ["frame", "inflate", "decode", "fingerprint"])
    func failuresIdentifyTheBrokenBoundary(_ boundary: String) throws {
        let encoded: String
        let expected: PackedNode.Failure
        switch boundary {
        case "frame": encoded = "~1"; expected = .frame
        case "inflate": encoded = CompactFrame(hash: 0, packed: [255, 255, 255]).text; expected = .inflate
        case "decode":
            let value = Array(#"{"notANode":true}"#.utf8)
            encoded = CompactFrame(hash: fnv1a(value), packed: try Deflate.compress(value, dictionary: WireDictionary.v1)).text
            expected = .decode
        default:
            let value = Array(#"{"text":"ET"}"#.utf8)
            encoded = CompactFrame(hash: 0, packed: try Deflate.compress(value, dictionary: WireDictionary.v1)).text
            expected = .frame
        }
        let drawing = try JSONDecoder().decode(PackedNode.self, from: JSONEncoder().encode(encoded))
        #expect(throws: expected) { try drawing.node() }
    }

    @Test(arguments: [#""~1bad""#, #"{"broken":true}"#, "42"])
    func aBadDrawingNeverDiscardsTheNotificationEnvelope(_ drawing: String) throws {
        let body = #"{"id":"00000000-0000-0000-0000-000000000001","sender":"bot","token":"test","drawing":\#(drawing)}"#
        let payload = try JSONDecoder().decode(NotificationPayload.self, from: Data(body.utf8))
        #expect(payload.sender == "bot")
        let drawing = try #require(payload.drawing)
        #expect(throws: PackedNode.Failure.frame) { try drawing.node() }
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
