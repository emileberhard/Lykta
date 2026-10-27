import LyktaCore
import SwiftUI
import WidgetKit

struct WidgetView: View {
    let layout: WidgetLayout
    let family: WidgetLayout.Family
    let widget: UUID?
    let isStale: Bool

    var body: some View {
        Root(node: layout.presentations[family], target: widget.map(Action.Target.widget), isStale: isStale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .invalidatableContent()
            .overlay(alignment: .topTrailing) {
                if isStale && !family.isAccessory {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Out of date")
                }
            }
            .widgetURL(layout.link)
    }
}

struct WidgetBackground: View {
    let background: WidgetLayout.Background?
    let isStale: Bool

    var body: some View {
        switch background {
        case let .paint(paint): Rectangle().fill(paint.style)
        case let .node(node): Root(node: node, target: nil, isStale: isStale)
        case nil: Rectangle().fill(.background)
        }
    }
}
