import Foundation
import Testing
@testable import LyktaCore

struct PartsTests {
    @Test func expandsNestedPartsBeforeFillingInEachScope() throws {
        let template = try json(#"""
        {"parts":{"row":{"hstack":[{"use":"name"},{"toggle":"item.done","label":"Done"}]},"name":{"text":"{{item.name}}","modifiers":[{"bold":true}]}},
         "lockScreen":{"vstack":[{"each":"items","as":"item","do":{"use":"row"}}]},
         "compactLeading":{"use":"name","modifiers":[{"italic":true}]},"compactTrailing":"","minimal":""}
        """#)
        let data = try json(#"{"item":{"name":"Outside"},"items":[{"name":"Milk","done":false},{"name":"Eggs","done":true}]}"#)
        let filled = try template.filled(with: data, for: .activity)
        #expect(try filled == json(#"""
        {"lockScreen":{"vstack":[{"hstack":[{"text":"Milk","modifiers":[{"bold":true}]},{"toggle":"items.0.done","isOn":false,"label":"Done"}]},
        {"hstack":[{"text":"Eggs","modifiers":[{"bold":true}]},{"toggle":"items.1.done","isOn":true,"label":"Done"}]}]},
        "compactLeading":{"text":"Outside","modifiers":[{"bold":true},{"italic":true}]},"compactTrailing":"","minimal":""}
        """#))
    }

    @Test(arguments: [false, true])
    func expandsBodyAndSavedPartsAtEveryNodePositionWithoutExpandingButtonData(saved: Bool) throws {
        let parts = saved ? "" : #""parts":{"word":"Hi"},"#
        let template = try json(#"""
        {\#(parts)"lockScreen":{"grid":[[{"if":true,"then":{"use":"word"},"else":{"use":"word"}}],
        [{"button":"go","label":{"use":"word"},"set":{"target":{"use":"literal"}},"modifiers":[{"overlay":{"use":"word"}}]}]]},
        "compactLeading":{"use":"word","modifiers":[{"bold":true}]},"compactTrailing":{"gauge":0.5,"currentValueLabel":{"use":"word"}},
        "minimal":{"use":"word"},"expanded":{"center":{"use":"word"}}}
        """#)
        let library: SavedParts = saved ? [Name(rawValue: "word")!: .string("Hi")] : [:]
        #expect(template.savedPartReferences().contains(Name(rawValue: "word")!) == saved)
        #expect(try PreparedParts(template, saved: library, for: .activity).value == json(#"""
        {"lockScreen":{"grid":[[{"if":true,"then":"Hi","else":"Hi"}],
        [{"button":"go","label":"Hi","set":{"target":{"use":"literal"}},"modifiers":[{"overlay":"Hi"}]}]]},
        "compactLeading":{"text":"Hi","modifiers":[{"bold":true}]},"compactTrailing":{"gauge":0.5,"currentValueLabel":"Hi"},
        "minimal":"Hi","expanded":{"center":"Hi"}}
        """#))
        let plain = try json(#"{"lockScreen":"Hi"}"#)
        #expect(try expanded(plain) == plain)
    }

    @Test func expandsPartsInsideEachGeneratedRowsAndModifiers() throws {
        let template = try json(#"""
        {"parts":{"cell":"{{row}}"},"lockScreen":{"grid":[{"each":"rows","as":"row","do":[{"use":"cell"}]}]},
         "compactLeading":{"text":"a","modifiers":[{"each":"rows","as":"row","do":{"overlay":{"use":"cell"}}}]},"compactTrailing":"","minimal":""}
        """#)
        #expect(try expanded(template) == json(#"""
        {"lockScreen":{"grid":[{"each":"rows","as":"row","do":["{{row}}"]}]},
         "compactLeading":{"text":"a","modifiers":[{"each":"rows","as":"row","do":{"overlay":"{{row}}"}}]},"compactTrailing":"","minimal":""}
        """#))
    }

    @Test func expandsPartsInsideAPartThatIsAnEach() throws {
        let template = try json(#"""
        {"parts":{"row":{"text":"{{item}}"},"rows":{"each":"items","as":"item","do":{"use":"row"}}},"lockScreen":{"vstack":[{"use":"rows"}]}}
        """#)
        #expect(try expanded(template) == json(#"""
        {"lockScreen":{"vstack":[{"each":"items","as":"item","do":{"text":"{{item}}"}}]}}
        """#))
    }

    @Test func expandsPartsInsideEachGeneratedModifiersAppendedAtAUse() throws {
        let template = try json(#"""
        {"parts":{"base":"Hi","cell":"{{row}}"},"lockScreen":{"use":"base","modifiers":[{"each":"rows","as":"row","do":{"overlay":{"use":"cell"}}}]}}
        """#)
        #expect(try expanded(template) == json(#"""
        {"lockScreen":{"text":"Hi","modifiers":[{"each":"rows","as":"row","do":{"overlay":"{{row}}"}}]}}
        """#))
    }

    @Test(arguments: [
        (#"{"parts":[],"minimal":""}"#, "parts: expected an object of named nodes"),
        (#"{"parts":{"z":"Z","a":"A"},"minimal":{"use":"missing"}}"#, #"minimal: unknown part "missing"; defined parts: a, z"#),
        (#"{"parts":{"unused":"A"},"minimal":""}"#, "parts.unused: part is not used"),
        (#"{"parts":{"a":{"use":"b"},"b":{"use":"a"}},"minimal":{"use":"a"}}"#, "parts.b: part cycle: a -> b -> a"),
        (#"{"parts":{"a":"A"},"minimal":{"use":"a","with":{}}}"#, #"minimal: expected {"use": "name"} with optional modifiers"#),
        (#"{"parts":{"a":"A"},"minimal":{"use":"a","modifiers":4}}"#, "minimal.modifiers: expected an array"),
    ])
    func rejectsInvalidDefinitionsAndUses(input: String, message: String) throws {
        #expect(throws: LayoutError(message)) { try expanded(json(input)) }
    }

    @Test func stopsAnExponentialGraphAtTheNodeBudget() throws {
        var parts: [String: JSONValue] = ["p0": .string("leaf")]
        for index in 1...30 {
            let use = JSONValue.object(["use": .string("p\(index - 1)")])
            parts["p\(index)"] = .object(["hstack": .array([use, use])])
        }
        let template = JSONValue.object(["parts": .object(parts), "lockScreen": .object(["use": .string("p30")])])
        #expect(throws: LayoutError("parts expand to more than 256 nodes")) { try expanded(template) }
    }

    @Test func acceptsTheNodeBudgetAndCountsAppendedOverlays() throws {
        let use = JSONValue.object(["use": .string("leaf")])
        var fields: [String: JSONValue] = [
            "parts": .object(["leaf": .string("Hi")]),
            "lockScreen": .object(["vstack": .array(Array(repeating: use, count: Layout.maximumNodes - 4))]),
            "compactLeading": use, "compactTrailing": use, "minimal": use, "small": .null,
        ]
        _ = try Layout(json: JSONValue.object(fields).filled(with: .object([:]), for: .activity).json)
        fields["minimal"] = .object(["use": .string("leaf"), "modifiers": .array([.object(["overlay": use])])])
        #expect(throws: LayoutError("parts expand to more than 256 nodes")) { try expanded(.object(fields)) }
    }

    @Test func appendedModifiersKeepTheirAuthoredPathsThroughAliases() throws {
        let template = try json(#"""
        {"parts":{"base":{"text":"Hi","modifiers":[{"bold":true}]},"alias":{"use":"base","modifiers":[{"italic":true}]}},
        "lockScreen":{"use":"alias","modifiers":[{"frame":{"width":-1}}]},"compactLeading":"","compactTrailing":"","minimal":""}
        """#)
        #expect(throws: LayoutError("lockScreen.modifiers[0].frame.width: must not be negative (used at lockScreen.modifiers[2])")) {
            try template.filled(with: .object([:]), for: .activity)
        }
    }

    @Test func resolvesLongAliasChainsWithoutRecursiveCopies() throws {
        var parts: [String: JSONValue] = ["p0": .string("leaf")]
        for index in 1...2_000 { parts["p\(index)"] = .object(["use": .string("p\(index - 1)")]) }
        let template = JSONValue.object(["parts": .object(parts), "minimal": .object(["use": .string("p2000")])])
        #expect(try expanded(template) == .object(["minimal": .string("leaf")]))
    }

    @Test(arguments: [false, true])
    func validationErrorsNameThePartInsideAndOutsideEach(repeated: Bool) throws {
        let node = repeated ? #"{"vstack":[{"each":"items","as":"item","do":{"use":"bad"}}]}"# : #"{"use":"bad"}"#
        let template = try json(#"{"parts":{"bad":{"symbol":"wifi","value":2}},"lockScreen":\#(node),"compactLeading":"","compactTrailing":"","minimal":""}"#)
        let site = repeated ? "lockScreen.vstack[0].do" : "lockScreen"
        #expect(throws: LayoutError("parts.bad.value: expected a value within 0...1 (used at \(site))")) {
            try template.filled(with: json(#"{"items":[1,2]}"#), for: .activity)
        }
    }

    @Test func missingDataNamesTheAuthoredPart() throws {
        let template = try json(#"{"parts":{"bad":{"text":"{{missing}}"}},"lockScreen":{"use":"bad"},"compactLeading":"","compactTrailing":"","minimal":""}"#)
        #expect(throws: LayoutError(#"parts.bad.text: data has no value at "missing" (used at lockScreen)"#)) {
            try template.filled(with: .object([:]), for: .activity)
        }
    }

    private func expanded(_ template: JSONValue) throws -> JSONValue {
        try PreparedParts(template, saved: [:], for: .activity).value
    }

    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
