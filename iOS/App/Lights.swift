import SwiftUI

@Animatable
struct Lights: View {
    private static let bounds = CGRect(x: 220, y: 244, width: 584, height: 524)
    private static let center = CGPoint(x: bounds.midX, y: bounds.midY)

    var separation: Double

    var body: some View {
        Canvas { context, size in
            let spread = CGSize(width: 137 * separation, height: 107 * separation)
            let bounds = Self.bounds.insetBy(dx: -spread.width, dy: -spread.height)
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.blendMode = .screen

            light(in: context, from: CGPoint(x: 531.64, y: 409.75)) {
                $0.fill(Path(ellipseIn: CGRect(x: 366.64, y: 244.75, width: 330, height: 330)), with: .color(red: 1, green: 0.310, blue: 0.545))
            }
            light(in: context, from: CGPoint(x: 648.55, y: 612.25)) {
                $0.fill(Path(roundedRect: CGRect(x: 493.55, y: 457.25, width: 310, height: 310), cornerRadius: 96),
                        with: .color(red: 1, green: 0.690, blue: 0.125))
            }
            light(in: context, from: CGPoint(x: 414.73, y: 612.25)) {
                var triangle = Path()
                triangle.addLines([CGPoint(x: 414.73, y: 420.25), CGPoint(x: 581, y: 708.25), CGPoint(x: 248.45, y: 708.25)])
                triangle.closeSubpath()
                $0.fill(triangle.union(triangle.strokedPath(StrokeStyle(lineWidth: 56, lineJoin: .round))),
                        with: .color(red: 0.184, green: 0.482, blue: 1))
            }
        }
        .compositingGroup()
        .aspectRatio(Self.bounds.width / Self.bounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func light(in context: GraphicsContext, from center: CGPoint, draw: (inout GraphicsContext) -> Void) {
        var context = context
        context.translateBy(x: (center.x - Self.center.x) * separation, y: (center.y - Self.center.y) * separation)
        draw(&context)
    }
}
