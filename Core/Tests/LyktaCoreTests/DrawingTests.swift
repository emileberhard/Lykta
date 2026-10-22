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

    @Test(arguments: [
        ("<svg><path d='M0 0'/></svg>", #"<svg>: give a viewBox, such as viewBox="0 0 24 24""#),
        ("<svg viewBox='0 0 9 9'><g><path class='a' d='M0 0'/></g></svg>", "<path> #1: class is not supported here"),
        ("<svg viewBox='0 0 9 9'><use href='#a'/></svg>", "<use> is not supported; use svg, g, path"),
        ("<svg viewBox='0 0 9 9'><rect width='9' height='9' fill='url(#nope)'/></svg>", #"<rect> #1: fill: no gradient has id "nope""#),
        ("<svg viewBox='0 0 9 9'><path id='orbit' d='M0 0 L5'/></svg>", #"<path id="orbit">: d: L needs more numbers"#),
        ("<svg viewBox='0 0 9 9'><circle r='2'>", "<circle> is never closed"),
    ])
    func rejectsWhatItCannotDrawWithTheElement(markup: String, message: String) {
        let error = #expect(throws: LayoutError.self) { try Drawing(svg: markup) }
        #expect(error?.description.hasPrefix(message) == true, "\(error?.description ?? "")")
    }
}
