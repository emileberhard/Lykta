import Foundation
import Testing
@testable import LyktaCore

struct CompatibilityTests {
    static let fixtures: [String: String] = [
        "link": #"{"link": "https://example.com", "label": "Open"}"#,
        "button": #"{"button": "ok", "label": "OK"}"#,
        "toggle": #"{"toggle": "on", "isOn": true, "label": "On"}"#,
        "grid": #"{"grid": [["a", "b"]]}"#,
        "chart": #"{"chart": [{"line": [1, 2]}]}"#,
        "symbol.value": #"{"symbol": "wifi", "value": 0.5}"#,
        "number": "5",
        "text.number": #"{"text": 5}"#,
        "if.bool": #"{"if": true, "then": "a"}"#,
        "modifiers.transition": #"{"text": "a", "modifiers": [{"transition": "opacity"}]}"#,
        "modifiers.animation": #"{"text": "a", "modifiers": [{"animation": {"value": 1}}]}"#,
        "modifiers.id": #"{"text": "a", "modifiers": [{"id": "x"}]}"#,
        "modifiers.overlay": #"{"text": "a", "modifiers": [{"overlay": "b"}]}"#,
        "modifiers.blur": #"{"text": "a", "modifiers": [{"blur": 2}]}"#,
        "modifiers.grayscale": #"{"text": "a", "modifiers": [{"grayscale": 0.5}]}"#,
        "modifiers.saturation": #"{"text": "a", "modifiers": [{"saturation": 2}]}"#,
        "modifiers.brightness": #"{"text": "a", "modifiers": [{"brightness": 0.1}]}"#,
        "modifiers.contentTransition.numericText": #"{"text": "a", "modifiers": [{"contentTransition": {"numericText": 3}}]}"#,
        "Modifier.ContentTransition.Name.symbolReplace": #"{"text": "a", "modifiers": [{"contentTransition": "symbolReplace"}]}"#,
        "Modifier.Transition.Name.slide": #"{"text": "a", "modifiers": [{"transition": "slide"}]}"#,
        "Modifier.Animation.Curve.spring": #"{"text": "a", "modifiers": [{"animation": {"curve": "spring", "value": 1}}]}"#,
        "Node.Content.ButtonStyle.bordered": #"{"button": "ok", "label": "OK", "style": "bordered"}"#,
        "Node.Content.ToggleStyle.checkbox": #"{"toggle": "on", "isOn": true, "label": "On", "style": "checkbox"}"#,
        "Node.Content.Chart.Mark.Interpolation.monotone": #"{"chart": [{"line": [1, 2], "interpolation": "monotone"}]}"#,
        "svg": #"{"svg": "<svg viewBox='0 0 1 1'><rect width='1' height='1'/></svg>"}"#,
        "color.shortHex": ##"{"text": "a", "modifiers": [{"foreground": "#abc"}]}"##,
        "color.rgb": #"{"text": "a", "modifiers": [{"foreground": "rgb(1, 2, 3)"}]}"#,
        "button.set": #"{"button": "ok", "label": "OK", "set": {"done": true}}"#,
        "button.add": #"{"button": "next", "label": "Next", "add": {"step": 1}}"#,
        "button.add.since": #"{"button": "resume", "label": "Resume", "add": {"end": {"since": "pausedAt"}}}"#,
        "button.now": #"{"button": "out", "label": "Out", "now": {"last": 0}}"#,
    ]

    @Test func detectsFeaturesAtTheirVersion() throws {
        for (feature, lockScreen) in Self.fixtures {
            let layout = try Layout(json: Array(Self.layout(lockScreen).utf8))
            #expect(layout.features.contains(feature), "\(feature)")
            #expect(layout.requirement?.version == Layout.introduced[feature], "\(feature)")
        }
        let appLink = try Layout(json: Array(Self.layout(#""a""#, extra: #", "link": "shortcuts://run""#).utf8))
        #expect(appLink.requirement == .init(version: Version(0, 2, 3), feature: "layout.link.appURL", path: "link"))
    }

    @Test func reportsTheNewestFeatureAtItsPath() throws {
        let layout = try Layout(json: Array(Self.layout(#"{"vstack": [{"text": "a", "modifiers": [{"blur": 1}]}, {"svg": "<svg viewBox='0 0 1 1'><rect width='1' height='1'/></svg>"}]}"#).utf8))
        #expect(layout.requirement == .init(version: Version(0, 2, 4), feature: "svg", path: "lockScreen.vstack[1].svg"))
        let baseline = try Layout(json: Array(Self.layout(##"{"text": "a", "modifiers": [{"foreground": "#AABBCC"}, {"contentTransition": "numericText"}]}"##).utf8))
        #expect(baseline.requirement == nil)
        #expect(Layout.version == Version(0, 5, 0))
    }

    @Test func recordsEveryWayAValueIsNamed() throws {
        let layout = try Layout(json: Array(Self.layout(#"""
            {"vstack": [{"text": "a", "modifiers": [{"foreground": "red"}, {"background": "secondary"}]}, {"chart": [{"bar": [1], "color": "blue"}]}]}
            """#).utf8))
        #expect(Set(["ColorValue.Name.red", "Paint.Level.secondary", "Node.Content.Chart.Mark.Kind.bar", "chart.bar.color", "ColorValue.Name.blue"])
            .isSubset(of: layout.features))
        #expect(!layout.features.contains("chart.bar.bar"))
        #expect(layout.features.allSatisfy { Layout.introduced[$0] != nil })
    }

    @Test func parsesVersions() {
        #expect(Version("0.2.3") == Version(0, 2, 3))
        #expect(Version(leading: "0.2.3 (41)") == Version(0, 2, 3))
        for text in ["1.0", "1.0 (1)", "+1.2.3", "1.2.3.4", "1.2.x", "", "1..2"] {
            #expect(Version(leading: text) == nil, "\(text)")
        }
        #expect(Version(0, 10, 0) > Version(0, 9, 9))
    }

    private static func layout(_ lockScreen: String, extra: String = "") -> String {
        #"{"lockScreen": \#(lockScreen), "compactLeading": "a", "compactTrailing": "b", "minimal": "c"\#(extra)}"#
    }
}
