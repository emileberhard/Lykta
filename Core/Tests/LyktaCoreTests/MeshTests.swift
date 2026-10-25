import Foundation
import Testing
@testable import LyktaCore

struct MeshTests {
    @Test func meshRecordsItsVersionAndGrid() throws {
        let paint = #"{"mesh":[[[0,0,"red"],[1,0,"blue"]],[[0,1,"green"],[1,1,"white"]]]}"#
        let json = layoutJSON(#"{"shape":"circle","fill":\#(paint)}"#)
        let layout = try Layout(json: Array(json.utf8))
        #expect(layout.requirement == .init(version: Version(0, 8, 0), feature: "paint.mesh", path: "lockScreen.fill.mesh"))
        let decoded = try JSONDecoder().decode(Paint.self, from: Data(paint.utf8))
        guard case let .mesh(mesh) = decoded else { Issue.record("expected mesh"); return }
        #expect(mesh.width == 2)
        #expect(mesh.height == 2)
        #expect(mesh.points.map(\.position) == [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)])
    }

    @Test(arguments: [
        (#"{"mesh":[]}"#, "lockScreen.fill.mesh: expected 2 to 4 rows"),
        (#"{"mesh":[[[0,0,"red"],[1,0,"blue"]],[[0,1,"green"]]]}"#, "lockScreen.fill.mesh[1]: expected 2 to 4 points per row, with equal row lengths"),
        (#"{"mesh":[[[0,0,"red"],[1,0,"blue"]],[[0,1,"green"],[1,1]]] }"#, "lockScreen.fill.mesh[1][1]: expected [x, y, color]"),
        (#"{"mesh":[[[0,0,"red"],[1,0,"blue"]],[[0,1,"green"],[2,1,"white"]]]}"#, "lockScreen.fill.mesh[1][1][0]: expected a coordinate within 0...1"),
        (#"{"mesh":[[[0,0,"red"],[1,0,"blue"]],[[0,1,"green"],[1,-1,"white"]]]}"#, "lockScreen.fill.mesh[1][1][1]: expected a coordinate within 0...1"),
        (#"{"mesh":[[[0,0,"red"],[1,0,"blue"]],[[0,1,"green"],[1,1,"invalid"]]]}"#, "lockScreen.fill.mesh[1][1][2]: expected #RGB, #RRGGBB, #RRGGBBAA, rgb(r, g, b), rgba(r, g, b, a) or one of red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, white, gray, black, clear, accent"),
        (#"{"mesh":[],"direction":"radial"}"#, "lockScreen.fill.direction: unknown key; expected mesh"),
        (#"{"colors":["red","blue"]}"#, "lockScreen.fill.colors: unknown key; expected direction, gradient, mesh"),
    ])
    func invalidMeshesReportExactPaths(paint: String, message: String) {
        #expect(throws: LayoutError(message)) {
            try Layout(json: Array(layoutJSON(#"{"shape":"circle","fill":\#(paint)}"#).utf8))
        }
    }
}
