import Foundation
import Testing
@testable import LyktaCore

struct WireTests {
    private static let json = Array(layoutJSON(#"{"text": "Gate 4 opens", "modifiers": [{"font": "headline"}]}"#).utf8)

    @Test func theDictionaryIsFrozen() {
        #expect(WireDictionary.v1.count == 32768)
        #expect(fingerprint(WireDictionary.v1) == "81a04d3b86e89505")
    }

    @Test(arguments: [
        ("Boarding", "da3a82cffe80d55f", "~1em*q5{[@3`;*3U&@VG|6tYJK)<C}&yQek]71#U+(gG((wx1(co>>!ODP4&,(cU{-{Ohhh>c>}e#(yc:87>i1 "),
        ("Boarding 18", "13ad19332d2a9f2", "~1Ck|w2E_Xey;*3U&@VG|6tYJK)<C}&yQek]71#U+(gG((wx1(co>>!ODP4&,(cU{-{Ohhh>c>}e#(yc:87>i1 "),
    ])
    func frozenCompactContentDecodesWithItsFingerprint(title: String, fingerprint: String, layout: String) throws {
        let state = try decode(title: title, layout: layout)
        #expect(state.fingerprint == fingerprint)
        let lockScreen = try #require(state.layout?.lockScreen)
        guard case .text("Gate 4 opens") = lockScreen.content else { Issue.record("expected the text node"); return }
        #expect(lockScreen.modifiers.count == 1)
        #expect(try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(state)) == ["title": title, "layout": layout])
    }

    @Test func phonesFromCompactSinceGetCompactContentWithTheLegacyFingerprint() throws {
        let legacy = try LyktaActivity.ContentState(title: "Boarding", layout: Self.json)
        #expect(try legacy.encoded(for: nil) == legacy)
        #expect(try legacy.encoded(for: Version(0, 7, 1)) == legacy)
        let compact = try legacy.encoded(for: LyktaActivity.ContentState.compactSince)
        let wire = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(compact))
        let text = try #require(wire["layout"])
        #expect(text.hasPrefix("~1"))
        #expect(text.utf8.count < (try #require(try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(legacy))["layout"])).utf8.count)
        let received = try decode(title: "Boarding", layout: text)
        #expect(received == compact)
        #expect(received.fingerprint == legacy.fingerprint)
        #expect(received.layout != nil)
    }

    @Test func bothFormsRoundTripThroughAPropertyListCoder() throws {
        let legacy = try LyktaActivity.ContentState(title: "Boarding", layout: Self.json)
        for state in [legacy, try legacy.encoded(for: LyktaActivity.ContentState.compactSince)] {
            let decoded = try PropertyListDecoder().decode(LyktaActivity.ContentState.self, from: PropertyListEncoder().encode(state))
            #expect(decoded == state)
            #expect(decoded.layout != nil)
        }
    }

    @Test(arguments: ["~1", "~1em*q5{[@3`;*3", "~1em*q5{[@3`;*3U&@VG|6tYJK)/C}"])
    func malformedCompactLayoutsFailToDecode(layout: String) {
        #expect(throws: DecodingError.self) { try decode(title: "Boarding", layout: layout) }
    }

    @Test func unreadableCompactContentStillReportsItsFingerprint() throws {
        let header: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]
        let state = try decode(title: "Boarding", layout: "~1" + Base92.encode(header + [0xff, 0xff, 0xff]))
        #expect(state.layout == nil)
        #expect(state.fingerprint == "123456789abcdef")
    }

    @Test(arguments: [[], [0], [255], [0, 255, 7], Array(0...255), Array(repeating: 0, count: 300)] as [[UInt8]])
    func base92RoundTripsWithoutQuotesSlashesOrBackslashes(bytes: [UInt8]) {
        let text = Base92.encode(bytes)
        #expect(!text.contains { #""/\"#.contains($0) })
        #expect(Base92.decode(Substring(text)) == bytes)
    }

    private func decode(title: String, layout: String) throws -> LyktaActivity.ContentState {
        try JSONDecoder().decode(LyktaActivity.ContentState.self, from: JSONValue.object(["title": .string(title), "layout": .string(layout)]).json.data)
    }
}

private extension Array where Element == UInt8 {
    var data: Data { Data(self) }
}
