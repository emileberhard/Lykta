import Foundation

public struct Drawing: Sendable {
    public static let maximumItems = 512
    public static let maximumSegments = 4096

    public struct Point: Sendable, Equatable {
        public var x, y: Double
    }

    public struct Rect: Sendable, Equatable {
        public var x, y, width, height: Double
    }

    public struct Transform: Sendable, Equatable {
        public static let identity = Transform(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

        public var a, b, c, d, e, f: Double

        func concatenating(_ inner: Transform) -> Transform {
            Transform(a: a * inner.a + c * inner.b, b: b * inner.a + d * inner.b,
                      c: a * inner.c + c * inner.d, d: b * inner.c + d * inner.d,
                      e: a * inner.e + c * inner.f + e, f: b * inner.e + d * inner.f + f)
        }
    }

    public enum Segment: Sendable, Equatable {
        case move(Point)
        case line(Point)
        case quad(Point, control: Point)
        case cubic(Point, control1: Point, control2: Point)
        case close
    }

    public struct Gradient: Sendable {
        public enum Shape: Sendable {
            case linear(from: Point, to: Point)
            case radial(center: Point, radius: Double)
        }

        public struct Stop: Sendable {
            public let offset: Double
            public let color: ColorValue
            public let opacity: Double
        }

        public let shape: Shape
        public let stops: [Stop]
        public let boundingBox: Rect?
    }

    public enum Paint: Sendable {
        case color(ColorValue)
        case foreground
        case gradient(Gradient)
    }

    public enum LineJoin: String, Choice { case miter, round, bevel }

    public struct Fill: Sendable {
        public let paint: Paint
        public let opacity: Double
        public let evenOdd: Bool
    }

    public struct Stroke: Sendable {
        public let paint: Paint
        public let opacity: Double
        public let width: Double
        public let cap: Node.Content.Shape.LineCap
        public let join: LineJoin
        public let miterLimit: Double
        public let dash: [Double]
        public let dashPhase: Double
    }

    public struct Label: Sendable {
        public enum Anchor: String, Choice { case start, middle, end }
        public enum Baseline: Sendable { case alphabetic, middle, hanging }

        public let text: String
        public let position: Point
        public let size: Double
        public let weight: Modifier.Weight
        public let design: Modifier.Design
        public let anchor: Anchor
        public let baseline: Baseline
    }

    public struct Item: Sendable {
        public enum Shape: Sendable {
            case path([Segment])
            case label(Label)
        }

        public let shape: Shape
        public let fill: Fill?
        public let stroke: Stroke?
        public let opacity: Double
        public let blur: Double
        public let transform: Transform
    }

    public let viewBox: Rect
    public let size: (width: Double, height: Double)?
    public let items: [Item]
}

extension Drawing {
    static func arc(from start: Point, to end: Point, radii: Point, rotation: Double, large: Bool, sweep: Bool) -> [Segment] {
        guard start != end else { return [] }
        var rx = abs(radii.x), ry = abs(radii.y)
        guard rx > 0, ry > 0 else { return [.line(end)] }
        let phi = rotation * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let coefficient = (large == sweep ? -1.0 : 1.0) * max(0, numerator / (rx * rx * y1 * y1 + ry * ry * x1 * x1)).squareRoot()
        let cx1 = coefficient * rx * y1 / ry, cy1 = -coefficient * ry * x1 / rx
        let center = Point(x: cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2, y: sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2)
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        let count = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(count), handle = 4 / 3 * tan(step / 4)
        func point(_ angle: Double) -> Point {
            Point(x: center.x + rx * cosPhi * cos(angle) - ry * sinPhi * sin(angle), y: center.y + rx * sinPhi * cos(angle) + ry * cosPhi * sin(angle))
        }
        func tangent(_ angle: Double) -> Point {
            Point(x: -rx * cosPhi * sin(angle) - ry * sinPhi * cos(angle), y: -rx * sinPhi * sin(angle) + ry * cosPhi * cos(angle))
        }
        return (0..<count).map { index in
            let from = theta + Double(index) * step, to = from + step
            let first = point(from), last = point(to), firstTangent = tangent(from), lastTangent = tangent(to)
            return .cubic(index == count - 1 ? end : last,
                          control1: Point(x: first.x + handle * firstTangent.x, y: first.y + handle * firstTangent.y),
                          control2: Point(x: last.x - handle * lastTangent.x, y: last.y - handle * lastTangent.y))
        }
    }

    static func measure(_ segments: [Segment]) -> (length: Double, bounds: Rect) {
        var length = 0.0
        var minimum = Point(x: .infinity, y: .infinity), maximum = Point(x: -.infinity, y: -.infinity)
        var current = Point(x: 0, y: 0), start = current
        func visit(_ point: Point, drawn: Bool = true) {
            if drawn { length += hypot(point.x - current.x, point.y - current.y) }
            minimum = Point(x: min(minimum.x, point.x), y: min(minimum.y, point.y))
            maximum = Point(x: max(maximum.x, point.x), y: max(maximum.y, point.y))
            current = point
        }
        func sample(_ curve: (Double) -> Point) {
            for step in 1...16 { visit(curve(Double(step) / 16)) }
        }
        for segment in segments {
            let origin = current
            switch segment {
            case let .move(point):
                visit(point, drawn: false)
                start = point
            case let .line(point): visit(point)
            case let .quad(point, control):
                sample { t in
                    let u = 1 - t
                    return Point(x: u * u * origin.x + 2 * u * t * control.x + t * t * point.x,
                                 y: u * u * origin.y + 2 * u * t * control.y + t * t * point.y)
                }
            case let .cubic(point, control1, control2):
                sample { t in
                    let u = 1 - t
                    return Point(x: u * u * u * origin.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * point.x,
                                 y: u * u * u * origin.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * point.y)
                }
            case .close: visit(start)
            }
        }
        guard minimum.x <= maximum.x else { return (0, Rect(x: 0, y: 0, width: 0, height: 0)) }
        return (length, Rect(x: minimum.x, y: minimum.y, width: maximum.x - minimum.x, height: maximum.y - minimum.y))
    }
}
