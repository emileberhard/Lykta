import LyktaCore
import SwiftUI

extension View {
    @ViewBuilder func modified(by modifier: Modifier) -> some View {
        switch modifier {
        case let .padding(insets):
            padding(EdgeInsets(top: insets.top, leading: insets.leading, bottom: insets.bottom, trailing: insets.trailing))
        case let .frame(frame):
            self.frame(width: frame.width.map { CGFloat($0) }, height: frame.height.map { CGFloat($0) }, alignment: frame.alignment.value)
                .frame(minWidth: frame.minWidth.map { CGFloat($0) }, maxWidth: frame.maxWidth.map { CGFloat($0) },
                       minHeight: frame.minHeight.map { CGFloat($0) }, maxHeight: frame.maxHeight.map { CGFloat($0) },
                       alignment: frame.alignment.value)
        case let .fixedSize(axes): fixedSize(horizontal: axes != .vertical, vertical: axes != .horizontal)
        case let .layoutPriority(priority): layoutPriority(priority)
        case let .offset(x, y): offset(x: x, y: y)
        case let .rotation(degrees): rotationEffect(.degrees(degrees))
        case let .scale(scale): scaleEffect(scale)
        case let .opacity(opacity): self.opacity(opacity)
        case let .foreground(paints) where paints.count == 3: foregroundStyle(paints[0].style, paints[1].style, paints[2].style)
        case let .foreground(paints) where paints.count == 2: foregroundStyle(paints[0].style, paints[1].style)
        case let .foreground(paints): foregroundStyle(paints[0].style)
        case let .background(paint): background(paint.style)
        case let .tint(paint): tint(paint.style)
        case let .clip(.cornerRadius(radius)): clipShape(.rect(cornerRadius: radius))
        case let .clip(.shape(kind)): clipShape(kind.shape(cornerRadius: 0))
        case let .shadow(shadow): self.shadow(color: shadow.color.value, radius: shadow.radius, x: shadow.x, y: shadow.y)
        case let .font(font): self.font(font.value)
        case let .fontWeight(weight): fontWeight(weight.value)
        case let .fontDesign(design): fontDesign(design.value)
        case let .fontWidth(width): fontWidth(width.value)
        case let .bold(isActive): bold(isActive)
        case let .italic(isActive): italic(isActive)
        case let .underline(isActive): underline(isActive)
        case let .strikethrough(isActive): strikethrough(isActive)
        case let .monospacedDigit(isActive): if isActive { monospacedDigit() } else { self }
        case let .tracking(tracking): self.tracking(tracking)
        case let .lineLimit(limit): lineLimit(limit)
        case let .minimumScaleFactor(factor): minimumScaleFactor(factor)
        case let .multilineTextAlignment(alignment): multilineTextAlignment(alignment.textValue)
        case let .truncationMode(mode): truncationMode(mode == .head ? .head : mode == .middle ? .middle : .tail)
        case let .textCase(textCase): self.textCase(textCase == .uppercase ? .uppercase : .lowercase)
        case let .contentTransition(transition): contentTransition(transition.value)
        case let .transition(transition): self.transition(transition.value)
        case let .animation(animation): self.animation(animation.value, value: animation.trigger)
        case let .id(id): self.id(id)
        case let .overlay(node): overlay { NodeView(node) }
        case let .blur(radius): blur(radius: radius)
        case let .grayscale(amount): grayscale(amount)
        case let .saturation(amount): saturation(amount)
        case let .brightness(amount): brightness(amount)
        case let .symbolRenderingMode(mode): symbolRenderingMode(mode.value)
        case let .imageScale(scale): imageScale(scale == .small ? .small : scale == .medium ? .medium : .large)
        case let .accessibilityLabel(label): accessibilityLabel(label)
        }
    }
}

extension Modifier.Font {
    var value: SwiftUI.Font {
        switch self {
        case let .size(size): .system(size: size)
        case let .style(style):
            switch style {
            case .largeTitle: .largeTitle
            case .title: .title
            case .title2: .title2
            case .title3: .title3
            case .headline: .headline
            case .subheadline: .subheadline
            case .body: .body
            case .callout: .callout
            case .footnote: .footnote
            case .caption: .caption
            case .caption2: .caption2
            }
        }
    }
}

extension Modifier.Weight {
    var value: SwiftUI.Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

extension Modifier.Design {
    var value: SwiftUI.Font.Design {
        switch self {
        case .default: .default
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        }
    }
}

extension Modifier.Width {
    var value: SwiftUI.Font.Width {
        switch self {
        case .compressed: .compressed
        case .condensed: .condensed
        case .standard: .standard
        case .expanded: .expanded
        }
    }
}

extension Modifier.ContentTransition {
    var value: ContentTransition {
        switch self {
        case .named(.numericText): .numericText()
        case .named(.opacity): .opacity
        case .named(.interpolate): .interpolate
        case .named(.identity): .identity
        case .named(.symbolReplace): .symbolEffect(.replace)
        case let .numericText(value): .numericText(value: value)
        }
    }
}

extension Modifier.Transition {
    var value: AnyTransition {
        switch self {
        case .named(.opacity): .opacity
        case .named(.slide): .slide
        case .named(.scale): .scale
        case .named(.identity): .identity
        case let .move(edge): .move(edge: edge.value)
        case let .push(edge): .push(from: edge.value)
        case let .combined(parts): parts.dropFirst().reduce(parts[0].value) { $0.combined(with: $1.value) }
        }
    }
}

extension Modifier.Transition.Edge {
    var value: Edge {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

extension Modifier.Animation {
    var value: SwiftUI.Animation {
        let animation: SwiftUI.Animation = switch curve {
        case .default: duration.map { .easeInOut(duration: $0) } ?? .default
        case .linear: .linear(duration: duration ?? 0.35)
        case .easeIn: .easeIn(duration: duration ?? 0.35)
        case .easeOut: .easeOut(duration: duration ?? 0.35)
        case .easeInOut: .easeInOut(duration: duration ?? 0.35)
        case .spring: .spring(duration: duration ?? 0.5)
        case .bouncy: .bouncy(duration: duration ?? 0.5)
        case .snappy: .snappy(duration: duration ?? 0.5)
        case .smooth: .smooth(duration: duration ?? 0.5)
        }
        return animation.delay(delay)
    }
}

extension Modifier.SymbolRendering {
    var value: SymbolRenderingMode {
        switch self {
        case .monochrome: .monochrome
        case .hierarchical: .hierarchical
        case .palette: .palette
        case .multicolor: .multicolor
        }
    }
}
