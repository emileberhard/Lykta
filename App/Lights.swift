import SwiftUI

struct Lights: View {
    private static let bounds = CGRect(x: 220, y: 244, width: 584, height: 524)

    var body: some View {
        Canvas { context, size in
            let bounds = Self.bounds
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2, y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            context.blendMode = .screen

            context.fill(Path(ellipseIn: CGRect(x: 366.64, y: 244.75, width: 330, height: 330)),
                         with: .color(red: 1, green: 0.310, blue: 0.545))
            context.fill(Path(roundedRect: CGRect(x: 493.55, y: 457.25, width: 310, height: 310), cornerRadius: 96),
                         with: .color(red: 1, green: 0.690, blue: 0.125))
            var triangle = Path()
            triangle.addLines([CGPoint(x: 414.73, y: 420.25), CGPoint(x: 581, y: 708.25), CGPoint(x: 248.45, y: 708.25)])
            triangle.closeSubpath()
            context.fill(triangle.union(triangle.strokedPath(StrokeStyle(lineWidth: 56, lineJoin: .round))),
                         with: .color(red: 0.184, green: 0.482, blue: 1))
        }
        .compositingGroup()
        .aspectRatio(Self.bounds.width / Self.bounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private extension GraphicsContext.Shading {
    static func color(red: Double, green: Double, blue: Double) -> Self {
        .color(Color(red: red, green: green, blue: blue))
    }
}
