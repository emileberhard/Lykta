import Foundation
import Testing
@testable import LyktaCore

struct LayoutTests {
    @Test(arguments: [
        (#"{"hstack": ["a", {"txt": "b"}]}"#, "lockScreen.hstack[1]: a node is a string or an object with one of"),
        (#"{"hstack": [], "colour": "red"}"#, "lockScreen.colour: unknown key; expected alignment, hstack, modifiers, spacing"),
        (#"{"text": "a", "modifiers": [{"padding": 4, "font": "body"}]}"#, "lockScreen.modifiers[0]: a modifier is an object with exactly one key"),
        (#"{"text": "a", "modifiers": [{"font": "huge"}]}"#, #"lockScreen.modifiers[0].font: "huge" is not one of largeTitle"#),
        (#"{"progress": 1.5}"#, "lockScreen.progress: expected a value within 0...1"),
        (#"{"concat": ["a", {"vstack": ["b"]}]}"#, "lockScreen.concat: parts must be"),
        (#"{"shape": "circle", "cornerRadius": 4}"#, "lockScreen.cornerRadius: only roundedRectangle"),
        (#"{"timer": ["2026-10-21T18:00:00Z", 0]}"#, "lockScreen.timer: expected [start, end] with start before end"),
    ])
    func rejectsInvalidNodesAtTheirPath(lockScreen: String, message: String) {
        #expect(error(in: layout(lockScreen)).hasPrefix(message))
    }

    @Test func rejectsMissingPresentationsAndPlainLinks() {
        #expect(error(in: #"{"lockScreen": "a"}"#) == #"missing "compactLeading""#)
        #expect(error(in: layout(#""a""#, extra: #", "link": "http://example.com""#)) == "link: must be an https URL")
    }

    @Test func boundsNesting() {
        let nested = (0..<16).reduce(#""a""#) { node, _ in #"{"vstack": [\#(node)]}"# }
        #expect(error(in: layout(nested)) == "nodes nest deeper than 16 levels")
    }

    @Test func demoSurvivesTheWire() throws {
        let json = try Demo.layout.filled(with: Demo.data(start: Date(timeIntervalSince1970: 1_800_000_000))).json
        let state = try LyktaActivity.ContentState(title: Demo.title, layout: json)
        let decoded = try JSONDecoder().decode(LyktaActivity.ContentState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded.layout != nil)
    }

    @Test func unreadableLayoutsFallBackToTheTitle() throws {
        let future = Data(try Deflate.compress(Array(layout(#"{"hologram": true}"#).utf8)))
        let wire = Data(#"{"title": "Build", "layout": "\#(future.base64EncodedString())"}"#.utf8)
        let state = try JSONDecoder().decode(LyktaActivity.ContentState.self, from: wire)
        #expect(state.title == "Build")
        #expect(state.layout == nil)
    }

    private func layout(_ lockScreen: String, extra: String = "") -> String {
        #"{"lockScreen": \#(lockScreen), "compactLeading": "a", "compactTrailing": "b", "minimal": "c"\#(extra)}"#
    }

    private func error(in json: String) -> String {
        do {
            _ = try Layout(json: Array(json.utf8))
            return "no error"
        } catch {
            return error.description
        }
    }
}

struct TemplateTests {
    let data: JSONValue = .object([
        "done": .number(3), "total": .number(5), "fraction": .number(0.6),
        "steps": .array([.object(["name": .string("Build")])]),
    ])

    @Test func wholePlaceholdersKeepTheirType() throws {
        #expect(try JSONValue.string("{{fraction}}").filled(with: data) == .number(0.6))
    }

    @Test func embeddedPlaceholdersBecomeText() throws {
        #expect(try JSONValue.string("{{done}} of {{ total }}: {{steps.0.name}}").filled(with: data) == .string("3 of 5: Build"))
    }

    @Test func missingAndCompoundValuesAreErrors() {
        #expect(throws: LayoutError(#"lockScreen: data has no value at "steps.1.name""#)) {
            try JSONValue.object(["lockScreen": .string("{{steps.1.name}}")]).filled(with: data)
        }
        #expect(throws: LayoutError(#"minimal[0]: data "steps" is not a single value"#)) {
            try JSONValue.object(["minimal": .array([.string("{{steps}}")])]).filled(with: data)
        }
    }
}
