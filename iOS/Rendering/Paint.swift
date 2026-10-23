import LyktaCore
import SwiftUI

extension Paint {
    var style: AnyShapeStyle {
        switch self {
        case let .color(color): AnyShapeStyle(color.value)
        case .level(.primary): AnyShapeStyle(.primary)
        case .level(.secondary): AnyShapeStyle(.secondary)
        case .level(.tertiary): AnyShapeStyle(.tertiary)
        case .level(.quaternary): AnyShapeStyle(.quaternary)
        case let .gradient(colors, direction): direction.style(Gradient(colors: colors.map(\.value)))
        }
    }
}

private extension Paint.Direction {
    func style(_ gradient: Gradient) -> AnyShapeStyle {
        switch self {
        case .vertical: AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: .top, endPoint: .bottom))
        case .horizontal: AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing))
        case .diagonal: AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        case .radial: AnyShapeStyle(EllipticalGradient(gradient: gradient))
        case .angular: AnyShapeStyle(AngularGradient(gradient: gradient, center: .center))
        }
    }
}

extension ColorValue {
    var value: Color {
        switch self {
        case let .rgb(red, green, blue, opacity): Color(red: red, green: green, blue: blue, opacity: opacity)
        case let .named(name):
            switch name {
            case .red: .red
            case .orange: .orange
            case .yellow: .yellow
            case .green: .green
            case .mint: .mint
            case .teal: .teal
            case .cyan: .cyan
            case .blue: .blue
            case .indigo: .indigo
            case .purple: .purple
            case .pink: .pink
            case .brown: .brown
            case .white: .white
            case .gray: .gray
            case .black: .black
            case .clear: .clear
            case .accent: .accentColor
            }
        }
    }
}
