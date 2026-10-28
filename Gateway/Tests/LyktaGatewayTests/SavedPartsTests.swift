import Foundation
import LyktaCore
import Testing
@testable import LyktaGateway

struct SavedPartsTests {
    private let store: Store
    private let api: API
    private let credentials: Credentials
    private let push = FakePush()
    private let now = Int(Date().timeIntervalSince1970)

    init() async throws {
        store = try Store(path: ":memory:")
        api = API(store: store, maximumDevices: 2, maximumLiveActivities: 2, environments: [.development],
                  enrolment: Enrolment(appID: AppAttestTests.appID), version: Version(9, 9, 9), shutdown: Shutdown())
        let registration = Registration(environment: .development, appVersion: Layout.version.description,
                                        proof: .invite(try await store.invite(now: now)))
        credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                       body: Array(try JSONEncoder().encode(registration)))).decoded()
        let report: JSONValue = ["pushToStartToken": "abcdef", "appVersion": .string(Layout.version.description),
                                 "layoutVersion": .string(Layout.version.description), "bundleInstance": .string(UUID().uuidString), "activities": .array([])]
        #expect(await api.handle(HTTPRequest(method: "PUT", target: "/v1/device", headers: ["authorization": "Bearer \(credentials.deviceSecret)"],
                                             body: report.json)).status == 200)
    }

    @Test func savesListsReplacesAndDeletesPartsWithoutWaiting() async throws {
        #expect(await send("PUT", "/v1/parts/z?wait=10", "Last").status == 201)
        #expect(await send("PUT", "/v1/parts/a", ["text": "First"]).status == 201)
        let replaced = await send("PUT", "/v1/parts/z", "Updated")
        #expect(replaced.status == 200)
        #expect(try replaced.decoded() as JSONValue == ["name": "z", "node": "Updated"])
        let listed = await send("GET", "/v1/parts")
        #expect(String(decoding: listed.body, as: UTF8.self) == #"{"parts":{"a":{"text":"First"},"z":"Updated"}}"#)
        #expect(await send("DELETE", "/v1/parts/z?wait=10").status == 204)
        #expect(try await send("DELETE", "/v1/parts/z").decoded() as Failure == Failure(error: "not_found"))
    }

    @Test(arguments: ["activities", "widgets"])
    func resolvesSavedPartsWithoutRootDefinitions(_ surface: String) async throws {
        #expect(await send("PUT", "/v1/parts/word", "Saved").status == 201)
        let response = await send("PUT", "/v1/\(surface)/example", request(surface, node: ["use": "word"]))
        #expect(response.status == (surface == "activities" ? 200 : 201))
        if surface == "activities" {
            try await deliver()
            #expect(try await drawnText() == "Saved")
        } else {
            let detail: JSONValue = try response.decoded()
            #expect(try detail.value(at: "layout.systemSmall") == "Saved")
        }
    }

    @Test func fillsASavedPlaceholderFromActivityData() async throws {
        #expect(await send("PUT", "/v1/parts/word", ["text": "{{word}}!"]).status == 201)
        #expect(await send("PUT", "/v1/activities/example", request("activities", node: ["use": "word"])).status == 200)
        try await deliver()
        #expect(try await drawnText() == "Data!")
    }

    @Test(arguments: [
        (JSONValue.object(["symbol": "wifi", "value": .number(2)]), "parts/bad.name.value: expected a value within 0...1 (used at lockScreen)"),
        (JSONValue.object(["text": "{{missing}}"]), #"parts/bad.name.text: data has no value at "missing" (used at lockScreen)"#),
        (JSONValue.object(["vstack": .array(["ok", ["if": .bool(true), "then": .bool(false)]])]), "parts/bad.name.vstack[1].then: Expected to decode Dictionary<String, Any> but found bool instead. (used at lockScreen.vstack[1].then)"),
        (JSONValue.object(["vstack": .array([["text": "x", "modifiers": ["bold": .bool(true)]]])]), "parts/bad.name.vstack[0].modifiers: Expected to decode Array<Any> but found a dictionary instead. (used at lockScreen.vstack[0])"),
        (JSONValue.object(["accessoryBackground": .bool(true)]), "parts/bad.name.accessoryBackground: accessoryBackground works only in accessoryCircular and accessoryRectangular (used at lockScreen)"),
    ])
    func savesAnyNodeAndNamesTheSavedPartAndItsUseSiteWhenItFails(_ node: JSONValue, _ message: String) async throws {
        #expect(await send("PUT", "/v1/parts/bad.name", node).status == 201)
        let refused: Refusal = try await send("PUT", "/v1/activities/example", request("activities", node: ["use": "bad.name"])).decoded()
        #expect(refused == Refusal(error: "invalid_layout", message: message))
    }

    @Test func aSavedModifierTemplateFillsFromData() async throws {
        #expect(await send("PUT", "/v1/parts/styled", ["text": "Hello", "modifiers": "{{style}}"]).status == 201)
        var body = request("activities", node: ["use": "styled"])
        body = try body.setting("data.style", to: .array([["bold": .bool(true)]]))
        #expect(await send("PUT", "/v1/activities/example", body).status == 200)
        try await deliver()
        #expect(try await drawnText() == "Hello")
    }

    @Test func aBodyPartCanUseASavedPart() async throws {
        _ = await send("PUT", "/v1/parts/word", "Saved")
        var body = request("activities", node: ["use": "label"])
        body = try body.setting("layout.parts.label", to: ["use": "word"])
        #expect(await send("PUT", "/v1/activities/example", body).status == 200)
        try await deliver()
        #expect(try await drawnText() == "Saved")
    }

    @Test func bodyPartsShadowSavedPartsAndOnlyBodyPartsMustBeUsed() async throws {
        _ = await send("PUT", "/v1/parts/word", "Saved")
        _ = await send("PUT", "/v1/parts/unused", "Unused")
        var body = request("activities", node: ["use": "word"])
        body = try body.setting("layout.parts.word", to: "Body")
        #expect(await send("PUT", "/v1/activities/example", body).status == 200)
        try await deliver()
        #expect(try await drawnText() == "Body")
    }

    @Test(arguments: [
        (false, false, #"lockScreen: unknown part "missing"; no parts are saved"#),
        (true, false, #"lockScreen: unknown part "missing"; defined parts: header; no parts are saved"#),
        (false, true, #"lockScreen: unknown part "missing"; saved parts: a, z"#),
        (true, true, #"lockScreen: unknown part "missing"; defined parts: header; saved parts: a, z"#),
    ])
    func anUnknownNameListsTheNamesThatExist(_ defined: Bool, _ saved: Bool, _ message: String) async throws {
        if saved {
            _ = await send("PUT", "/v1/parts/z", "Z")
            _ = await send("PUT", "/v1/parts/a", "A")
        }
        var body = request("activities", node: ["use": "missing"])
        if defined { body = try body.setting("layout.parts.header", to: "Header") }
        let refused: Refusal = try await send("PUT", "/v1/activities/example", body).decoded()
        #expect(refused == Refusal(error: "invalid_layout", message: message))
    }

    @Test(arguments: ["replace", "delete"])
    func libraryChangesLeaveALiveActivitySnapshotIntact(_ change: String) async throws {
        _ = await send("PUT", "/v1/parts/word", ["text": "Old {{word}}"])
        #expect(await send("PUT", "/v1/activities/example", request("activities", node: ["use": "word"])).status == 200)
        try await deliver()
        if change == "replace" { _ = await send("PUT", "/v1/parts/word", "Replacement") }
        else { _ = await send("DELETE", "/v1/parts/word") }
        #expect(await send("PUT", "/v1/activities/example", ["data": ["word": "Changed"]]).status == 200)
        try await deliver(at: now + 1)
        #expect(try await drawnText() == "Old Changed")
    }

    @Test func savedToSavedReferencesAreSnapshotsAtSaveTime() async throws {
        _ = await send("PUT", "/v1/parts/inner", ["text": "Original {{word}}"])
        let outer = await send("PUT", "/v1/parts/outer", ["use": "inner"])
        #expect(outer.status == 201)
        #expect(try outer.decoded() as JSONValue == ["name": "outer", "node": ["text": "Original {{word}}"]])
        _ = await send("PUT", "/v1/parts/inner", "Changed")
        _ = await send("DELETE", "/v1/parts/inner")
        let refused: Refusal = try await send("PUT", "/v1/parts/again", ["use": "inner"]).decoded()
        #expect(refused == Refusal(error: "invalid_layout", message: #"part: unknown part "inner"; saved parts: outer"#))
        #expect(await send("PUT", "/v1/activities/example", request("activities", node: ["use": "outer"])).status == 200)
        try await deliver()
        #expect(try await drawnText() == "Original Data")
    }

    @Test func the64PartLimitAllowsReplacementAndReclaimsDeletedNames() async throws {
        for index in 0..<64 { #expect(await send("PUT", "/v1/parts/p\(index)", "Part").status == 201) }
        let refused = await send("PUT", "/v1/parts/extra", "Extra")
        #expect(refused.status == 409)
        #expect(try refused.decoded() as Refusal == Refusal(error: "too_many_parts", message: "Delete a saved part before saving another; the limit is 64."))
        #expect(await send("PUT", "/v1/parts/p0", "Replacement").status == 200)
        #expect(await send("DELETE", "/v1/parts/p1").status == 204)
        #expect(await send("PUT", "/v1/parts/extra", "Extra").status == 201)
    }

    @Test func anotherPhonesTokenCannotReadUseReplaceOrDeleteParts() async throws {
        _ = await send("PUT", "/v1/parts/private", "Private")
        let registration = Registration(environment: .development, appVersion: Layout.version.description,
                                        proof: .invite(try await store.invite(now: now)))
        let other: Credentials = try await api.handle(HTTPRequest(method: "POST", target: "/v1/devices", headers: [:],
                                                                  body: Array(try JSONEncoder().encode(registration)))).decoded()
        func otherSend(_ method: String, _ path: String, _ body: JSONValue?) async -> HTTPResponse {
            await api.handle(HTTPRequest(method: method, target: path, headers: ["authorization": "Bearer \(other.agentToken)"], body: body?.json ?? []))
        }
        #expect(try await otherSend("GET", "/v1/parts", nil).decoded() as JSONValue == ["parts": .object([:])])
        let refused: Refusal = try await otherSend("PUT", "/v1/widgets/private", request("widgets", node: ["use": "private"])).decoded()
        #expect(refused.error == "invalid_layout")
        #expect(await otherSend("DELETE", "/v1/parts/private", nil).status == 404)
        #expect(await otherSend("PUT", "/v1/parts/private", "Other").status == 201)
        #expect(try await send("GET", "/v1/parts").decoded() as JSONValue == ["parts": ["private": "Private"]])
    }

    @Test func aWidgetOnlyNodeIsValidAtAWidgetPresentation() async throws {
        #expect(await send("PUT", "/v1/parts/background", ["accessoryBackground": .bool(true)]).status == 201)
        #expect(await send("PUT", "/v1/widgets/example", ["title": "Widget", "layout": ["accessoryCircular": ["use": "background"]]]).status == 201)
    }

    @Test(arguments: [
        (JSONValue.bool(true), "part: expected a node object or text shorthand"),
        (JSONValue.null, "part: expected a node object or text shorthand"),
        (JSONValue.array([]), "part: expected a node object or text shorthand"),
        (JSONValue.object(["parts": .object([:]), "text": .string("No")]), "parts: a saved part cannot define parts; save each part separately"),
        (JSONValue.string(String(repeating: "x", count: Layout.maximumBytes)), "part is \(Layout.maximumBytes + 2) bytes; the limit is \(Layout.maximumBytes)"),
    ])
    func savingRefusesWhatIsNoNodeOrTooLarge(_ node: JSONValue, _ message: String) async throws {
        let refused: Refusal = try await send("PUT", "/v1/parts/bad", node).decoded()
        #expect(refused == Refusal(error: "invalid_layout", message: message))
        #expect(try await send("GET", "/v1/parts").decoded() as JSONValue == ["parts": .object([:])])
    }

    @Test(arguments: [Layout.maximumNodes - 4, Layout.maximumNodes - 3])
    func aSavedPartCountsTowardTheExpansionBudgetAtItsUse(_ children: Int) async throws {
        #expect(await send("PUT", "/v1/parts/wide", ["hstack": .array(Array(repeating: "x", count: children))]).status == 201)
        let response = await send("PUT", "/v1/activities/example", request("activities", node: ["use": "wide"]))
        if children == Layout.maximumNodes - 4 { #expect(response.status == 200) }
        else { #expect(try response.decoded() as Refusal == Refusal(error: "invalid_layout", message: "parts expand to more than 256 nodes")) }
    }

    @Test func templatesWithoutPartsKeepTheirFilledNodeBudget() async throws {
        let repeated: JSONValue = ["each": "items", "as": "item", "do": ["hstack": .array(Array(repeating: "x", count: Layout.maximumNodes))]]
        let body: JSONValue = ["title": "Empty", "layout": ["systemSmall": ["vstack": .array([repeated])]], "data": ["items": .array([])]]
        #expect(await send("PUT", "/v1/widgets/example", body).status == 201)
    }

    @Test func eventsContainOnlyTheNameAndFingerprint() async throws {
        _ = await send("PUT", "/v1/parts/word", "Private text")
        _ = await send("DELETE", "/v1/parts/word")
        let events: Events = try await send("GET", "/v1/events").decoded()
        let parts = events.events.filter { $0.name.hasPrefix("part.") }
        #expect(parts.map(\.name) == ["part.put", "part.delete"])
        #expect(parts.map(\.detail) == Array(repeating: ["name": "word", "fingerprint": .string(fingerprint(JSONValue.string("Private text").json))], count: 2))
    }

    private func request(_ surface: String, node: JSONValue) -> JSONValue {
        let layout: JSONValue = surface == "widgets" ? ["systemSmall": node]
            : ["lockScreen": node, "compactLeading": "", "compactTrailing": "", "minimal": ""]
        return ["title": "Saved", "layout": layout, "data": ["word": "Data"]]
    }

    private func send(_ method: String, _ path: String, _ body: JSONValue? = nil) async -> HTTPResponse {
        await api.handle(HTTPRequest(method: method, target: path, headers: ["authorization": "Bearer \(credentials.agentToken)"], body: body?.json ?? []))
    }

    private func deliver(at time: Int? = nil) async throws {
        let delivery = Delivery(store: store, push: push, shutdown: Shutdown())
        for job in try await store.claim(now: time ?? now, limit: 4) {
            try await store.finish(job, try await delivery.send(job, now: time ?? now), now: time ?? now)
        }
    }

    private func drawnText() async throws -> String {
        let packed = try #require(push.layouts.last)
        let state: LyktaActivity.ContentState = try JSONDecoder().decode(LyktaActivity.ContentState.self, from: Data(JSONValue.object(["title": "Saved", "layout": .string(packed)]).json))
        guard case let .text(text) = try #require(state.layout).lockScreen.content else {
            Issue.record("Expected a text node")
            return ""
        }
        return text
    }
}
