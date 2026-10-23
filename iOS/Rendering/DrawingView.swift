import LyktaCore
import SwiftUI

struct DrawingView: View {
    let drawing: Drawing

    var body: some View {
        let box = drawing.viewBox
        let canvas = Canvas { context, size in
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(x: (size.width - box.width * scale) / 2 - box.x * scale, y: (size.height - box.height * scale) / 2 - box.y * scale)
            context.scaleBy(x: scale, y: scale)
            for item in drawing.items { item.draw(in: context, scale: scale) }
        }
        Group {
            if let size = drawing.size {
                canvas.frame(width: size.width, height: size.height)
            } else {
                FittedLayout(viewBox: CGSize(width: box.width, height: box.height)) { canvas }
            }
        }
        .accessibilityLabel(drawing.title ?? "")
        .accessibilityHidden(drawing.title == nil)
    }
}

private struct FittedLayout: SwiftUI.Layout {
    let viewBox: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let ratio = viewBox.width / viewBox.height
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        switch (width, height) {
        case let (width?, height?): return width / ratio <= height ? CGSize(width: width, height: width / ratio) : CGSize(width: height * ratio, height: height)
        case let (width?, nil): return CGSize(width: width, height: width / ratio)
        case let (nil, height?): return CGSize(width: height * ratio, height: height)
        case (nil, nil): return viewBox
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private extension Drawing.Item {
    func draw(in context: GraphicsContext, scale: Double) {
        var context = context
        context.concatenate(transform.value)
        let scale = scale * abs(transform.a * transform.d - transform.b * transform.c).squareRoot()
        context.opacity = opacity
        if blur > 0 { context.addFilter(.blur(radius: blur * scale)) }
        switch shape {
        case let .group(items):
            context.drawLayer { layer in
                for item in items { item.draw(in: layer, scale: scale) }
            }
        case let .path(segments):
            let path = Path(segments)
            if opacity < 1, fill != nil, stroke != nil {
                context.drawLayer { layer in draw(path, in: layer) }
            } else {
                draw(path, in: context)
            }
        case let .label(label):
            guard let fill else { return }
            paint(fill.paint, opacity: fill.opacity, in: context, region: (Path(), FillStyle())) { context, shading in
                var text = context.resolve(Text(verbatim: label.text)
                    .font(.system(size: label.size, weight: label.weight.value, design: label.design.value)))
                text.shading = shading
                let size = text.measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
                let x = switch label.anchor {
                case .start: label.position.x
                case .middle: label.position.x - size.width / 2
                case .end: label.position.x - size.width
                }
                let y = switch label.baseline {
                case .alphabetic: label.position.y - text.firstBaseline(in: size)
                case .middle: label.position.y - size.height / 2
                case .hanging: label.position.y
                }
                context.draw(text, in: CGRect(x: x, y: y, width: size.width, height: size.height))
            }
        }
    }

    private func draw(_ path: Path, in context: GraphicsContext) {
        if let fill {
            let style = FillStyle(eoFill: fill.evenOdd)
            paint(fill.paint, opacity: fill.opacity, in: context, region: (path, style)) { $0.fill(path, with: $1, style: style) }
        }
        if let stroke {
            let style = StrokeStyle(lineWidth: stroke.width, lineCap: stroke.cap.value, lineJoin: stroke.join.value,
                                    miterLimit: stroke.miterLimit, dash: stroke.dash.map { CGFloat($0) }, dashPhase: stroke.dashPhase)
            paint(stroke.paint, opacity: stroke.opacity, in: context, region: (path.strokedPath(style), FillStyle())) {
                $0.stroke(path, with: $1, style: style)
            }
        }
    }

    private func paint(_ paint: Drawing.Paint, opacity: Double, in context: GraphicsContext, region: @autoclosure () -> (Path, FillStyle),
                       draw: (inout GraphicsContext, GraphicsContext.Shading) -> Void) {
        var context = context
        context.opacity *= opacity
        switch paint {
        case let .color(color): draw(&context, .color(color.value))
        case .foreground: draw(&context, .foreground)
        case let .gradient(gradient):
            let (path, style) = region()
            context.clip(to: path, style: style)
            var area = path.boundingRect
            if let box = gradient.boundingBox {
                guard box.width > 0, box.height > 0 else { return }
                let units = CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.x, ty: box.y)
                context.concatenate(units)
                area = area.applying(units.inverted())
            }
            let stops = Gradient(stops: gradient.stops.map { Gradient.Stop(color: $0.color.value.opacity($0.opacity), location: $0.offset) })
            let shading: GraphicsContext.Shading = switch gradient.shape {
            case let .linear(from, to): .linearGradient(stops, startPoint: from.value, endPoint: to.value)
            case let .radial(center, radius): .radialGradient(stops, center: center.value, startRadius: 0, endRadius: radius)
            }
            context.fill(Path(area), with: shading)
        }
    }
}

private extension Path {
    init(_ segments: [Drawing.Segment]) {
        self.init()
        for segment in segments {
            switch segment {
            case let .move(point): move(to: point.value)
            case let .line(point): addLine(to: point.value)
            case let .quad(point, control): addQuadCurve(to: point.value, control: control.value)
            case let .cubic(point, control1, control2): addCurve(to: point.value, control1: control1.value, control2: control2.value)
            case .close: closeSubpath()
            }
        }
    }
}

private extension Drawing.Point {
    var value: CGPoint { CGPoint(x: x, y: y) }
}

private extension Drawing.Transform {
    var value: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f) }
}

private extension Drawing.LineJoin {
    var value: CGLineJoin {
        switch self {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}
