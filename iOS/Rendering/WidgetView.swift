import LyktaCore
import SwiftUI
import WidgetKit

struct WidgetView: View {
    let layout: WidgetLayout
    let family: WidgetLayout.Family
    let isStale: Bool

    var body: some View {
        Root(node: layout.presentations[family], activity: nil, isStale: isStale)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if isStale {
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
        case let .node(node): Root(node: node, activity: nil, isStale: isStale)
        case nil: Rectangle().fill(.background)
        }
    }
}
