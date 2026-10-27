import Foundation
import Testing
@testable import LyktaCore

struct WidgetLayoutTests {
    @Test(arguments: [
        (##"{"background": "#112233"}"##, "a widget needs at least one of systemSmall"),
        (#"{"systemSmall": "a", "lockScreen": "b"}"#, "lockScreen: unknown key; expected background, link, systemSmall"),
        (#"{"systemSmall": {"button": "go", "label": "Go"}}"#, "systemSmall.button: buttons and toggles work only in Live Activities"),
        (#"{"systemSmall": {"vstack": [{"toggle": "done", "isOn": true, "label": "Done"}]}}"#, "systemSmall.vstack[0].toggle: buttons and toggles work only in Live Activities"),
        (#"{"systemSmall": "a", "background": {"link": "https://example.com", "label": "Open"}}"#, "background.link: a widget's background takes no links, buttons or toggles"),
        (#"{"systemSmall": "a", "link": "http://example.com"}"#, "link: expected an https URL or an app URL such as shortcuts://"),
        (#"{"systemSmall": {"text": "a", "modifiers": [{"padding": 4}]}, "background": {"vstack": [], "colour": "red"}}"#, "background.colour: unknown key"),
    ])
    func rejectsWidgetsAtTheirPath(json: String, message: String) {
        #expect(error(in: json).hasPrefix(message), "\(error(in: json))")
    }

    @Test func linksWorkInsideASmallWidget() throws {
        let widget = try decode(#"{"systemSmall": {"link": "https://example.com/steps", "label": "Steps"}, "link": "shortcuts://run"}"#)
        #expect(widget.presentations.keys.sorted { $0.rawValue < $1.rawValue } == [.systemSmall])
        #expect(widget.link == URL(string: "shortcuts://run"))
    }

    @Test(arguments: [
        (##""#0A7D3B""##, false),
        (##"{"gradient": ["#34C759", "#0A7D3B"], "direction": "diagonal"}"##, false),
        (#"{"text": "6,400"}"#, true),
        (#"{"svg": "<svg viewBox='0 0 1 1'><rect width='1' height='1'/></svg>"}"#, true),
    ])
    func readsABackgroundAsAPaintOrANode(background: String, isNode: Bool) throws {
        let widget = try decode(##"{"systemSmall": "a", "background": \##(background)}"##)
        switch widget.background {
        case .node: #expect(isNode)
        case .paint: #expect(!isNode)
        case nil: Issue.record("no background")
        }
    }

    @Test func sharesTheLayoutBudgetsAcrossPresentationAndBackground() {
        let half = Array(repeating: #""a""#, count: Layout.maximumNodes / 2).joined(separator: ", ")
        #expect(error(in: #"{"systemSmall": {"vstack": [\#(half)]}, "background": {"vstack": [\#(half)]}}"#)
            == "layout has more than \(Layout.maximumNodes) nodes")
    }

    @Test func requiresTheReleaseThatFirstDrewWidgets() throws {
        let widget = try decode(##"{"systemSmall": {"if": "showsBackground", "then": "a", "else": "b"}, "background": "#000000", "link": "https://example.com"}"##)
        #expect(Set(["widget.systemSmall", "widget.background", "widget.link", "Node.Content.Condition.Environment.showsBackground"])
            .isSubset(of: widget.features))
        #expect(widget.requirement?.version == Layout.introduced["widget.systemSmall"])
        #expect(widget.features.allSatisfy { Layout.introduced[$0] != nil })
    }

    @Test(arguments: ["fullColor", "accented", "showsBackground"])
    func recordsTheRenderingConditionsInActivitiesToo(condition: String) throws {
        let layout = try Layout(json: Array(layoutJSON(#"{"if": "\#(condition)", "then": "a"}"#).utf8))
        #expect(layout.requirement?.feature == "Node.Content.Condition.Environment.\(condition)")
    }

    @Test func expandsPartsInEveryWidgetRootAndLocatesTheirErrors() throws {
        let template = try json(#"{"parts": {"count": {"text": "{{steps}}"}}, "systemSmall": {"use": "count"}, "background": {"use": "count"}}"#)
        let filled = try template.filled(with: .object(["steps": .string("6,400")]), for: .widget)
        #expect(filled == (try json(#"{"systemSmall": {"text": "6,400"}, "background": {"text": "6,400"}}"#)))

        let controls = try json(#"{"parts": {"go": {"button": "go", "label": "Go"}}, "systemSmall": {"use": "go"}}"#)
        #expect(throws: LayoutError("parts.go.button: buttons and toggles work only in Live Activities (used at systemSmall)")) {
            try controls.filled(with: .object([:]), for: .widget)
        }
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func decode(_ json: String) throws(LayoutError) -> WidgetLayout {
        try WidgetLayout(json: Array(json.utf8))
    }

    private func error(in json: String) -> String {
        do {
            _ = try decode(json)
            return "no error"
        } catch {
            return error.description
        }
    }
}
