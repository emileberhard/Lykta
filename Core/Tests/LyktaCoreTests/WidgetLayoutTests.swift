import Foundation
import Testing
@testable import LyktaCore

struct WidgetLayoutTests {
    @Test(arguments: [
        (##"{"background": "#112233"}"##, "a widget needs at least one of systemSmall, systemMedium, systemLarge, accessoryCircular, accessoryRectangular, accessoryInline"),
        (#"{"systemSmall": "a", "lockScreen": "b"}"#, "lockScreen: unknown key; expected accessoryCircular, accessoryInline, accessoryRectangular, background, link, systemLarge, systemMedium, systemSmall"),
        (#"{"accessoryInline": {"vstack": ["a", "b"]}}"#, "accessoryInline: takes only text, concat, symbol, date and timer nodes with text modifiers and privacySensitive, or an if choosing between them; a concat with both a symbol and a relative date or timer holds only the symbol and then that one part"),
        (#"{"accessoryInline": {"if": "vibrant", "then": "a", "else": {"gauge": 0.5}}}"#, "accessoryInline: takes only text"),
        (#"{"accessoryInline": {"text": "a", "modifiers": [{"padding": 4}]}}"#, "accessoryInline: takes only text"),
        (#"{"accessoryInline": {"concat": [{"symbol": "clock"}, "Next ", {"date": 1793000000, "style": "relative"}]}}"#,
         "accessoryInline: takes only text"),
        (#"{"systemSmall": {"zstack": [{"accessoryBackground": true}, "a"]}}"#, "systemSmall.zstack[0].accessoryBackground: accessoryBackground works only in accessoryCircular and accessoryRectangular"),
        (#"{"accessoryCircular": {"accessoryBackground": false}}"#, "accessoryCircular.accessoryBackground: expected true"),
        (#"{"accessoryCircular": {"link": "https://example.com", "label": "a"}}"#, "accessoryCircular.link: links work only in systemSmall, systemMedium, systemLarge and accessoryRectangular"),
        (#"{"systemSmall": "a", "background": {"text": "a", "modifiers": [{"privacySensitive": true}]}}"#, "background.modifiers[0].privacySensitive: privacySensitive works only in a widget's presentations"),
        (#"{"accessoryInline": {"button": "go", "label": "Go"}}"#, "accessoryInline.button: buttons and toggles work only in systemSmall, systemMedium, systemLarge, accessoryCircular and accessoryRectangular"),
        (#"{"accessoryInline": {"toggle": "done", "isOn": true, "label": "Done"}}"#, "accessoryInline.toggle: buttons and toggles work only in systemSmall, systemMedium, systemLarge, accessoryCircular and accessoryRectangular"),
        (#"{"systemSmall": "a", "background": {"button": "go", "label": "Go"}}"#, "background.button: buttons and toggles work only in systemSmall, systemMedium, systemLarge, accessoryCircular and accessoryRectangular"),
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

    @Test func takesASymbolBeforeOneRelativeDateOnOneLine() throws {
        let widget = try decode(#"{"accessoryInline": {"concat": [{"symbol": "clock"}, {"date": 1793000000, "style": "relative"}]}}"#)
        #expect(widget.presentations[.accessoryInline] != nil)
    }

    @Test func drawsEveryFamilyWithItsOwnNode() throws {
        let widget = try decode(#"""
            {"systemSmall": "s", "systemMedium": "m", "systemLarge": "l",
             "accessoryCircular": {"zstack": [{"accessoryBackground": true}, {"gauge": 0.5}]},
             "accessoryRectangular": {"text": "6,400", "modifiers": [{"privacySensitive": true}]},
             "accessoryInline": {"if": "vibrant", "then": {"concat": [{"symbol": "figure.walk"}, " 6,400"], "modifiers": [{"bold": true}, {"privacySensitive": true}]}, "else": "6,400 steps", "modifiers": [{"privacySensitive": true}]}}
            """#)
        #expect(Set(widget.presentations.keys) == Set(WidgetLayout.Family.allCases))
        #expect(widget.requirement?.version == Version(0, 13, 0))
        #expect(Set(["accessoryBackground", "modifiers.privacySensitive", "Node.Content.Condition.Environment.vibrant"]).isSubset(of: widget.features))
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

        let controls = try json(#"{"parts": {"go": {"button": "go", "label": "Go"}}, "accessoryInline": {"use": "go"}}"#)
        #expect(throws: LayoutError("parts.go.button: buttons and toggles work only in systemSmall, systemMedium, systemLarge, accessoryCircular and accessoryRectangular (used at accessoryInline)")) {
            try controls.filled(with: .object([:]), for: .widget)
        }
    }

    @Test(arguments: WidgetLayout.Family.allCases.filter { $0 != .accessoryInline })
    func widgetControlsRequireTheirOwnReleaseAndExposeOnlyShownControls(family: WidgetLayout.Family) throws {
        let widget = try decode(#"{"\#(family.rawValue)": {"vstack": [{"button": "add", "label": "+", "add": {"count": 1}}, {"toggle": "done", "isOn": false, "label": "Done"}, {"if": false, "then": {"button": "hidden", "label": "Hidden"}}]}}"#)
        #expect(Set(widget.buttons.keys) == ["add"])
        #expect(widget.toggles == ["done": false])
        #expect(widget.requirement?.version == Version(0, 14, 0))
        #expect(Set(["widget.button", "widget.toggle"]).isSubset(of: widget.features))
        #expect(widget.features.allSatisfy { Layout.introduced[$0] != nil })
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
