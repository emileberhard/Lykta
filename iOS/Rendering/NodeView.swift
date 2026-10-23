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
        case let .symbol(name, value):
            Image(systemName: name, variableValue: value)
        case let .shape(shape):
            ShapeNodeView(shape: shape)
        case let .svg(drawing):
            DrawingView(drawing: drawing)
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
        case let .conditional(.value(holds), then, otherwise):
            if holds {
                NodeView(then)
            } else if let otherwise {
                NodeView(otherwise)
            }
        case let .conditional(.environment(condition), then, otherwise):
            ConditionalNodeView(condition: condition, then: then, otherwise: otherwise)
        case let .link(url, label):
            Link(destination: url) { NodeView(label) }
        case let .button(name, label, style, _):
            ButtonNodeView(name: name, label: label, style: style)
        case let .toggle(path, isOn, label, style):
            ToggleNodeView(path: path, isOn: isOn, label: label, style: style)
        case let .grid(rows, alignment, horizontalSpacing, verticalSpacing):
            Grid(alignment: alignment.value, horizontalSpacing: horizontalSpacing.map { CGFloat($0) },
                 verticalSpacing: verticalSpacing.map { CGFloat($0) }) {
                ForEach(rows.indices, id: \.self) { row in
                    GridRow { Children(nodes: rows[row]) }
                }
            }
        case let .chart(chart):
            ChartNodeView(chart: chart)
        case let .concat(parts):
            HStack(alignment: .firstTextBaseline, spacing: 0) { Children(nodes: parts) }
        case .text, .timer, .date:
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
        let style = StrokeStyle(lineWidth: shape.lineWidth, lineCap: shape.lineCap.value, dash: shape.dash.map { CGFloat($0) })
        switch (shape.fill, shape.stroke) {
        case let (fill?, stroke?): outline.fill(fill.style).stroke(stroke.style, style: style)
        case let (fill?, nil): outline.fill(fill.style)
        case let (nil, stroke?): outline.stroke(stroke.style, style: style)
        case (nil, nil): outline
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
            ProgressView(value: interval.progress(at: pausedAt, countsDown: countsDown))
        case let .interval(interval, countsDown, nil):
            #if LYKTA_APP
            TimelineView(ProgressSchedule(interval: interval)) { context in
                ProgressView(value: interval.progress(at: context.date, countsDown: countsDown))
            }
            #else
            ProgressView(timerInterval: interval, countsDown: countsDown) { EmptyView() } currentValueLabel: { EmptyView() }
            #endif
        }
    }
}

#if LYKTA_APP
private struct ProgressSchedule: TimelineSchedule {
    private static let steps = 1000.0

    let interval: ClosedRange<Date>

    func entries(from start: Date, mode: TimelineScheduleMode) -> UnfoldFirstSequence<Date> {
        let step = interval.upperBound.timeIntervalSince(interval.lowerBound) / Self.steps
        return sequence(first: start) { date in
            guard date < interval.upperBound else { return nil }
            let next = max(date.addingTimeInterval(step), interval.lowerBound)
            return next > date ? min(next, interval.upperBound) : interval.upperBound
        }
    }
}
#endif

private extension ClosedRange<Date> {
    func progress(at date: Date, countsDown: Bool) -> Double {
        let elapsed = date.timeIntervalSince(lowerBound) / upperBound.timeIntervalSince(lowerBound)
        let fraction = Swift.min(Swift.max(elapsed.isFinite ? elapsed : 1, 0), 1)
        return countsDown ? 1 - fraction : fraction
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

private struct ButtonNodeView: View {
    let name: String
    let label: Node
    let style: Node.Content.ButtonStyle
    @Environment(\.activityID) private var activity

    var body: some View {
        switch style {
        case .automatic: button
        case .plain: button.buttonStyle(.plain)
        case .bordered: button.buttonStyle(.bordered)
        case .borderedProminent: button.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var button: some View {
        if let activity {
            Button(intent: ButtonIntent(activity: activity, button: name)) { NodeView(label) }
        } else {
            Button {} label: { NodeView(label) }
        }
    }
}

private struct ToggleNodeView: View {
    let path: String
    let isOn: Bool
    let label: Node
    let style: Node.Content.ToggleStyle
    @Environment(\.activityID) private var activity

    var body: some View {
        switch style {
        case .switch: toggle.toggleStyle(.switch)
        case .button: toggle.toggleStyle(.button)
        case .checkbox: toggle.toggleStyle(CheckboxToggleStyle())
        }
    }

    @ViewBuilder private var toggle: some View {
        if let activity {
            Toggle(isOn: isOn, intent: ToggleIntent(activity: activity, toggle: path, isOn: !isOn)) { NodeView(label) }
        } else {
            Toggle(isOn: .constant(isOn)) { NodeView(label) }
        }
    }
}

private struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ConditionalNodeView: View {
    let condition: Node.Content.Condition.Environment
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

private extension Node.Content {
    var isSymbol: Bool {
        if case .symbol = self { true } else { false }
    }

    var isSelfUpdating: Bool {
        switch self {
        case .timer: true
        case let .date(_, style): style != .time && style != .date
        default: false
        }
    }
}

extension EnvironmentValues {
    @Entry var isActivityStale = false
    @Entry var activityID: UUID?
}

private extension Text {
    init?(_ node: Node, inline: Bool = false) {
        switch node.content {
        case let .text(text): self.init(verbatim: text)
        case let .symbol(name, value) where inline: self.init(Image(systemName: name, variableValue: value))
        case let .timer(interval, countsDown, pausedAt, showsHours):
            self.init(timerInterval: interval, pauseTime: pausedAt, countsDown: countsDown, showsHours: showsHours)
        case let .date(date, style): self.init(date, style: style.value)
        case let .concat(parts) where !(parts.contains(where: \.content.isSymbol) && parts.contains(where: \.content.isSelfUpdating)):
            self = parts.reduce(Text(verbatim: "")) { text, part in Text("\(text)\(Text(part, inline: true) ?? Text(verbatim: ""))") }
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

extension Node.Content.Shape.LineCap {
    var value: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}

extension Node.Content.Shape.Kind {
    func shape(cornerRadius: Double) -> AnyShape {
        switch self {
        case .rectangle: AnyShape(Rectangle())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: cornerRadius))
        case .circle: AnyShape(Circle())
        case .ellipse: AnyShape(Ellipse())
        case .capsule: AnyShape(Capsule())
        case .containerRelativeShape: AnyShape(ContainerRelativeShape())
        }
    }
}

extension Node.Content.DateStyle {
    var value: Text.DateStyle {
        switch self {
        case .time: .time
        case .date: .date
        case .relative: .relative
        case .offset: .offset
        case .timer: .timer
        }
    }
}

extension Node.Content.HorizontalAlignment {
    var value: SwiftUI.HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var textValue: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension Node.Content.VerticalAlignment {
    var value: SwiftUI.VerticalAlignment {
        switch self {
        case .top: .top
        case .center: .center
        case .bottom: .bottom
        case .firstTextBaseline: .firstTextBaseline
        case .lastTextBaseline: .lastTextBaseline
        }
    }
}

extension Node.Content.Alignment {
    var value: SwiftUI.Alignment {
        switch self {
        case .center: .center
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}
