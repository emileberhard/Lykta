import LyktaCore
import SwiftUI
import WidgetKit

struct NodeView: View {
    let node: Node

    init(_ node: Node) {
        self.node = node
    }

    var body: some View {
        if let text = Text(node) {
            node.modifiers.filter { !$0.isTextModifier }.reduce(AnyView(text)) { AnyView($0.modified(by: $1)) }
        } else {
            node.modifiers.reduce(AnyView(content)) { AnyView($0.modified(by: $1)) }
        }
    }

    @ViewBuilder private var content: some View {
        switch node.content {
        case let .symbol(name):
            Image(systemName: name)
        case let .shape(shape):
            ShapeNodeView(shape: shape)
        case let .hstack(children, alignment, spacing):
            HStack(alignment: alignment.value, spacing: spacing.map { CGFloat($0) }) { Children(nodes: children) }
        case let .vstack(children, alignment, spacing):
            VStack(alignment: alignment.value, spacing: spacing.map { CGFloat($0) }) { Children(nodes: children) }
        case let .zstack(children, alignment):
            ZStack(alignment: alignment.value) { Children(nodes: children) }
        case let .viewThatFits(children, axis):
            ViewThatFits(in: axis.map { $0 == .horizontal ? .horizontal : .vertical } ?? [.horizontal, .vertical]) {
                Children(nodes: children)
            }
        case let .spacer(minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })
        case .divider:
            Divider()
        case let .progress(progress, style):
            ProgressNodeView(progress: progress, style: style)
        case let .gauge(gauge):
            GaugeNodeView(gauge: gauge)
        case let .conditional(condition, then, otherwise):
            ConditionalNodeView(condition: condition, then: then, otherwise: otherwise)
        case .text, .timer, .date, .concat:
            EmptyView()
        }
    }
}

private struct Children: View {
    let nodes: [Node]

    var body: some View {
        ForEach(nodes.indices, id: \.self) { NodeView(nodes[$0]) }
    }
}

private struct ShapeNodeView: View {
    let shape: Node.Content.Shape

    var body: some View {
        let outline = shape.kind.shape(cornerRadius: shape.cornerRadius).trim(from: shape.trim.lowerBound, to: shape.trim.upperBound)
        let style = StrokeStyle(lineWidth: shape.lineWidth, lineCap: cap, dash: shape.dash.map { CGFloat($0) })
        switch (shape.fill, shape.stroke) {
        case let (fill?, stroke?): outline.fill(fill.style).stroke(stroke.style, style: style)
        case let (fill?, nil): outline.fill(fill.style)
        case let (nil, stroke?): outline.stroke(stroke.style, style: style)
        case (nil, nil): outline
        }
    }

    private var cap: CGLineCap {
        switch shape.lineCap {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}

private struct ProgressNodeView: View {
    let progress: Node.Content.Progress
    let style: Node.Content.ProgressStyle

    var body: some View {
        switch style {
        case .linear: view.progressViewStyle(.linear)
        case .circular: view.progressViewStyle(.circular)
        }
    }

    @ViewBuilder private var view: some View {
        switch progress {
        case let .value(value):
            ProgressView(value: value)
        case let .interval(interval, countsDown, pausedAt?):
            let elapsed = pausedAt.timeIntervalSince(interval.lowerBound) / interval.upperBound.timeIntervalSince(interval.lowerBound)
            let fraction = min(max(elapsed.isFinite ? elapsed : 1, 0), 1)
            ProgressView(value: countsDown ? 1 - fraction : fraction)
        case let .interval(interval, countsDown, nil):
            ProgressView(timerInterval: interval, countsDown: countsDown) { EmptyView() } currentValueLabel: { EmptyView() }
        }
    }
}

private struct GaugeNodeView: View {
    let gauge: Node.Content.Gauge

    var body: some View {
        let view = Gauge(value: gauge.value, in: gauge.range) {
            if let label = gauge.label { NodeView(label) }
        } currentValueLabel: {
            if let label = gauge.currentValueLabel { NodeView(label) }
        } minimumValueLabel: {
            if let label = gauge.minimumValueLabel { NodeView(label) }
        } maximumValueLabel: {
            if let label = gauge.maximumValueLabel { NodeView(label) }
        }
        switch gauge.style {
        case .circular: view.gaugeStyle(.accessoryCircular)
        case .circularCapacity: view.gaugeStyle(.accessoryCircularCapacity)
        case .linear: view.gaugeStyle(.accessoryLinear)
        case .linearCapacity: view.gaugeStyle(.accessoryLinearCapacity)
        }
    }
}

private struct ConditionalNodeView: View {
    let condition: Node.Content.Condition
    let then: Node
    let otherwise: Node?
    @Environment(\.isActivityStale) private var isStale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.isActivityFullscreen) private var isFullscreen
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        let holds = switch condition {
        case .stale: isStale
        case .dark: colorScheme == .dark
        case .luminanceReduced: isLuminanceReduced
        case .fullscreen: isFullscreen
        case .limitedWidth: isLimitedInWidth
        }
        if holds {
            NodeView(then)
        } else if let otherwise {
            NodeView(otherwise)
        }
    }
}

extension EnvironmentValues {
    @Entry var isActivityStale = false
}

private extension Text {
    init?(_ node: Node, inline: Bool = false) {
        switch node.content {
        case let .text(text): self.init(verbatim: text)
        case let .symbol(name) where inline: self.init(Image(systemName: name))
        case let .timer(interval, countsDown, pausedAt, showsHours):
            self.init(timerInterval: interval, pauseTime: pausedAt, countsDown: countsDown, showsHours: showsHours)
        case let .date(date, style): self.init(date, style: style.value)
        case let .concat(parts): self = parts.reduce(Text(verbatim: "")) { text, part in Text("\(text)\(Text(part, inline: true) ?? Text(verbatim: ""))") }
        default: return nil
        }
        self = node.modifiers.filter(\.isTextModifier).reduce(self) { $0.styled(by: $1) }
    }

    func styled(by modifier: Modifier) -> Text {
        switch modifier {
        case let .font(font): self.font(font.value)
        case let .fontWeight(weight): fontWeight(weight.value)
        case let .fontDesign(design): fontDesign(design.value)
        case let .fontWidth(width): fontWidth(width.value)
        case let .bold(isActive): bold(isActive)
        case let .italic(isActive): italic(isActive)
        case let .underline(isActive): underline(isActive)
        case let .strikethrough(isActive): strikethrough(isActive)
        case let .monospacedDigit(isActive): isActive ? monospacedDigit() : self
        case let .tracking(tracking): self.tracking(tracking)
        case let .foreground(paints): foregroundStyle(paints[0].style)
        default: self
        }
    }
}
