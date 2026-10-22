import Testing
@testable import LyktaCore

struct DrawingTests {
    @Test func readsCompactPathDataAndEndsArcsExactly() throws {
        let drawing = try Drawing(svg: "<svg viewBox='0 0 40 20'><path d='M0 0L10-5.5.5 1h2v1e1zm20 10a5 5 0 1 0 10 0'/></svg>")
        guard case let .path(segments) = drawing.items[0].shape else {
            Issue.record("not a path")
            return
        }
        let point = Drawing.Point.init
        #expect(Array(segments.prefix(6)) == [.move(point(0, 0)), .line(point(10, -5.5)), .line(point(0.5, 1)), .line(point(2.5, 1)),
                                              .line(point(2.5, 11)), .close])
        #expect(segments[6] == .move(point(20, 10)))
        guard case let .cubic(end, _, _) = segments.last else {
            Issue.record("the arc did not end in a curve")
            return
        }
        #expect(end == point(30, 10))
        let tiny = try Drawing(svg: "<svg viewBox='0 0 9 9'><path d='M0 0A1e-200 1e-200 0 0 1 1 1'/></svg>")
        guard case let .path(tinySegments) = tiny.items[0].shape else {
            Issue.record("not a path")
            return
        }
        #expect(tinySegments.last == .line(point(1, 1)))
    }

    @Test func pathLengthScalesDashesSoADotSitsAtAFraction() throws {
        let drawing = try Drawing(svg: """
            <svg viewBox='0 0 100 20'><path d='M0 10H100' stroke='#fff' pathLength='1' stroke-dasharray='0 2' \
            stroke-dashoffset='-0.25' stroke-linecap='round'/></svg>
            """)
        let stroke = try #require(drawing.items[0].stroke)
        #expect(stroke.dash == [0, 200])
        #expect(abs(stroke.dashPhase - 175) < 0.001)
        #expect(stroke.cap == .round)
    }

    @Test func gradientsInBoundingBoxUnitsUseTheShapesBounds() throws {
        let drawing = try Drawing(svg: """
            <svg width='48' viewBox='0 0 24 12'><defs><radialGradient id='glow'><stop offset='0' stop-color='#FFF'/>\
            <stop offset='100%' stop-color='rgba(0, 0, 255, 0.5)'/></radialGradient></defs>\
            <circle cx='12' cy='6' r='4' fill='url(#glow)'/></svg>
            """)
        #expect(drawing.size?.width == 48 && drawing.size?.height == 24)
        guard case let .gradient(gradient)? = drawing.items[0].fill?.paint else {
            Issue.record("not a gradient fill")
            return
        }
        let box = try #require(gradient.boundingBox)
        #expect(abs(box.x - 8) < 0.001 && abs(box.width - 8) < 0.001)
        #expect(gradient.stops.count == 2)
    }

    @Test func ignoresIconMarkupThatDoesNotDrawAndKeepsGroupsWhole() throws {
        let drawing = try Drawing(svg: """
            <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' class='lucide' aria-hidden='true' data-slot='icon' \
            fill='none' stroke='currentColor' stroke-dasharray='4px, 2'><title>Done</title><g opacity='.5'><path d='M20 6 9 17'/>\
            <path d='M9 17l-5-5'/></g></svg>
            """)
        #expect(drawing.title == "Done")
        guard case let .group(children) = drawing.items[0].shape else {
            Issue.record("not a group")
            return
        }
        #expect(drawing.items.count == 1 && drawing.items[0].opacity == 0.5)
        #expect(children.count == 2 && children.allSatisfy { $0.opacity == 1 && $0.stroke?.dash == [4, 2] })
    }

    @Test(arguments: [
        ("<svg><path d='M0 0'/></svg>", #"<svg>: give a viewBox, such as viewBox="0 0 24 24""#),
        ("<svg viewBox='0 0 9 9'><g><path clip-path='url(#a)' d='M0 0'/></g></svg>", "<path> #1: clip-path is not supported here"),
        ("<svg viewBox='0 0 9 9'><svg/></svg>", "<svg> #2: only the root may be <svg>"),
        ("<svg viewBox='0 0 9 9'><text stroke='red'>A</text></svg>", "<text> #1: stroke: text is filled, not stroked"),
        ("<svg viewBox='0 0 9 9'><text fill='none'>A</text></svg>", "<text> #1: fill: text needs a fill"),
        ("<svg viewBox='0 0 9 9'><filter id='a'><feGaussianBlur stdDeviation='1'/></filter><linearGradient id='a'/></svg>",
         #"<linearGradient id="a">: another gradient or filter has this id"#),
        ("<svg viewBox='0 0 9 9'><path d='M0 0H9' stroke='red' pathLength='1e-320'/></svg>", "<path> #1: pathLength: too small"),
        ("<svg viewBox='0 0 9 9'><g transform='scale(1e200)'><g transform='scale(1e200)'/></g></svg>", "<g> #2: transform: scales beyond"),
        ("<svg viewBox='0 0 9 9'><use href='#a'/></svg>", "<use> is not supported; use svg, g, path"),
        ("<svg viewBox='0 0 9 9'><rect width='9' height='9' fill='url(#nope)'/></svg>", #"<rect> #1: fill: no gradient has id "nope""#),
        ("<svg viewBox='0 0 9 9'><path id='orbit' d='M0 0 L5'/></svg>", #"<path id="orbit">: d: L needs more numbers"#),
        ("<svg viewBox='0 0 9 9'><circle r='2'>", "<circle> is never closed"),
        ("<svg viewBox='0 0 9 9'><rect width='9' height='9' fill='#ＦＦＦ'/></svg>", "<rect> #1: fill: expected none, currentColor"),
        ("<svg viewBox='0 0 9 9'><path d='M0 0H100' stroke='red' stroke-dasharray='.01'/></svg>", "<path> #1: stroke-dasharray: the dashes are too short"),
    ])
    func rejectsWhatItCannotDrawWithTheElement(markup: String, message: String) {
        let error = #expect(throws: LayoutError.self) { try Drawing(svg: markup) }
        #expect(error?.description.hasPrefix(message) == true, "\(error?.description ?? "")")
    }
}
