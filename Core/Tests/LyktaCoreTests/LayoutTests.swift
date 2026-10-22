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
        (#"{"button": "Retry", "label": "Retry"}"#, "lockScreen.button: use 1 to 64 lowercase letters"),
        (#"{"button": "retry", "label": {"link": "https://example.com", "label": "Open"}}"#, "lockScreen.label: a label cannot contain links, buttons or toggles"),
        (#"{"chart": [{"bar": [1, 2], "colors": ["red"]}]}"#, "lockScreen.chart[0].colors: give one color per value"),
        (#"{"chart": [{"sector": [1], "lineWidth": 2}]}"#, "lockScreen.chart[0].lineWidth: unknown key"),
        (#"{"text": "a", "modifiers": [{"animation": {"curve": "spring", "duration": 3, "value": 1}}]}"#, "lockScreen.modifiers[0].animation.duration: must be between 0.05 and 2.0"),
        (#"{"text": "a", "modifiers": [{"transition": [{"move": "top"}, ["opacity", "scale"]]}]}"#, "lockScreen.modifiers[0].transition"),
        (#"{"svg": "<svg viewBox='0 0 9 9'><path d='M0 0' fill='tomato'/></svg>"}"#, "lockScreen.svg: <path> #1: fill: expected none, currentColor"),
    ])
    func rejectsInvalidNodesAtTheirPath(lockScreen: String, message: String) {
        #expect(error(in: layout(lockScreen)).hasPrefix(message))
    }

    @Test func rejectsMissingPresentationsAndUnsafeLinks() {
        #expect(error(in: #"{"lockScreen": "a"}"#) == #"missing "compactLeading""#)
        for url in ["http://example.com", "javascript:alert(1)", "file:///etc/hosts"] {
            #expect(error(in: layout(#""a""#, extra: #", "link": "\#(url)""#)) == "link: expected an https URL or an app URL such as shortcuts://")
        }
        #expect(error(in: layout(#""a""#, extra: #", "link": "shortcuts://run-shortcut?name=Lights""#)) == "no error")
    }

    @Test func placesControlsOnlyWhereTheyWork() {
        let compact = #"{"lockScreen": "a", "compactLeading": {"button": "go", "label": "Go"}, "compactTrailing": "b", "minimal": "c"}"#
        #expect(error(in: compact) == "compactLeading.button: links, buttons and toggles work only in lockScreen and expanded")
    }

    @Test func collectsTheControlsAnActionMayName() throws {
        let json = layout(#"{"vstack": [{"button": "retry", "label": "Retry"}, {"toggle": "items.0.done", "isOn": true, "label": "Milk"}]}"#,
                          extra: #", "expanded": {"bottom": {"button": "stop", "label": "Stop", "style": "borderedProminent"}}"#)
        let layout = try Layout(json: Array(json.utf8))
        #expect(layout.buttons == ["retry", "stop"])
        #expect(layout.toggles == ["items.0.done": true])
    }

    @Test func numbersFromDataRenderAsText() throws {
        let layout = try Layout(json: Array(layout(#"{"hstack": [3, {"text": 0.5}]}"#).utf8))
        guard case let .hstack(nodes, _, _) = layout.lockScreen.content else {
            Issue.record("not an hstack")
            return
        }
        #expect(nodes.map { if case let .text(text) = $0.content { text } else { "" } } == ["3", "0.5"])
    }

    @Test func boundsNesting() {
        let nested = (0..<16).reduce(#""a""#) { node, _ in #"{"vstack": [\#(node)]}"# }
        #expect(error(in: layout(nested)) == "nodes nest deeper than 16 levels")
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

    @Test func valuesInsertedIntoSVGMarkupAreEscaped() throws {
        let data = try json(#"{"team": "R&D <'x'>", "icon": "<svg/>"}"#)
        #expect(try json(#"{"svg": "<text>{{team}}</text>", "text": "Team {{team}}"}"#).filled(with: data)
            == json(#"{"svg": "<text>R&amp;D &lt;&apos;x&apos;&gt;</text>", "text": "Team R&D <'x'>"}"#))
        #expect(try json(#"{"svg": "{{icon}}"}"#).filled(with: data) == json(#"{"svg": "<svg/>"}"#))
    }

    @Test func missingAndCompoundValuesAreErrors() {
        #expect(throws: LayoutError(#"lockScreen: data has no value at "steps.1.name""#)) {
            try JSONValue.object(["lockScreen": .string("{{steps.1.name}}")]).filled(with: data)
        }
        #expect(throws: LayoutError(#"minimal[0]: data "steps" is not a single value and cannot be inserted into text"#)) {
            try JSONValue.object(["minimal": .array([.string("Steps: {{steps}}")])]).filled(with: data)
        }
    }

    @Test func eachRepeatsItsItemForEveryEntry() throws {
        let template = try json(#"["Steps", {"each": "steps", "as": "step", "do": {"text": "{{step.name}}"}}]"#)
        #expect(try template.filled(with: data) == json(#"["Steps", {"text": "Build"}]"#))
        #expect(throws: LayoutError(#"[1].each: data "done" is not a list"#)) {
            try json(#"["Steps", {"each": "done", "as": "step", "do": "x"}]"#).filled(with: data)
        }
    }

    @Test func togglesReadTheirStateFromTheirDataPath() throws {
        let data = try json(#"{"items": [{"name": "Milk", "done": true}]}"#)
        let template = try json(#"[{"each": "items", "as": "item", "do": {"toggle": "item.done", "label": "{{item.name}}"}}]"#)
        #expect(try template.filled(with: data) == json(#"[{"toggle": "items.0.done", "isOn": true, "label": "Milk"}]"#))
        #expect(throws: LayoutError("isOn: a toggle reads isOn from the data at its path")) {
            try json(#"{"toggle": "items.0.done", "isOn": false, "label": "Milk"}"#).filled(with: data)
        }
    }

    @Test func replacesOneValueAtADataPath() throws {
        let data = try json(#"{"items": [{"done": false}]}"#)
        #expect(try data.replacing("items.0.done", with: .bool(true)) == json(#"{"items": [{"done": true}]}"#))
        #expect(throws: LayoutError(#"data has no value at "items.1.done""#)) { try data.replacing("items.1.done", with: .bool(true)) }
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
