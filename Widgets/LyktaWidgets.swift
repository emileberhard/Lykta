import LyktaCore
import SwiftUI
import WidgetKit

@main
struct LyktaWidgets: WidgetBundle {
    var body: some Widget {
        LyktaLiveActivity()
    }
}

struct LyktaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyktaActivity.self) { context in
            LockScreenView(state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let layout = context.state.layout
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Root(node: layout?.expanded?.leading, isStale: isStale).dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Root(node: layout?.expanded?.trailing, isStale: isStale).dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.center) {
                    Root(node: layout?.expanded?.center, isStale: isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if layout == nil {
                        Fallback(title: context.state.title)
                    } else {
                        Root(node: layout?.expanded?.bottom, isStale: isStale)
                    }
                }
            } compactLeading: {
                Root(node: layout?.compactLeading, isStale: isStale).compact()
            } compactTrailing: {
                if layout == nil {
                    Text(context.state.title).compact()
                } else {
                    Root(node: layout?.compactTrailing, isStale: isStale).compact()
                }
            } minimal: {
                Root(node: layout?.minimal, isStale: isStale).compact()
            }
            .keylineTint(layout?.keyline?.value)
            .widgetURL(layout?.link)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct LockScreenView: View {
    let state: LyktaActivity.ContentState
    let isStale: Bool
    @Environment(\.activityFamily) private var family

    var body: some View {
        content
            .overlay(alignment: .topTrailing) {
                if isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .accessibilityLabel("Out of date")
                }
            }
            .activityBackgroundTint(state.layout?.background?.value)
            .widgetURL(state.layout?.link)
    }

    @ViewBuilder private var content: some View {
        if let layout = state.layout {
            if family == .small, let small = layout.small {
                Root(node: small, isStale: isStale)
            } else if family == .small {
                HStack {
                    Root(node: layout.compactLeading, isStale: isStale)
                    Spacer(minLength: 4)
                    Root(node: layout.compactTrailing, isStale: isStale)
                }
                .compact()
                .padding(12)
            } else {
                Root(node: layout.lockScreen, isStale: isStale)
            }
        } else {
            Fallback(title: state.title).padding(16)
        }
    }
}

private struct Root: View {
    let node: Node?
    let isStale: Bool

    var body: some View {
        if let node {
            NodeView(node).environment(\.isActivityStale, isStale)
        }
    }
}

private struct Fallback: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text("Update Lykta to show this activity.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func compact() -> some View {
        lineLimit(1).minimumScaleFactor(0.5)
    }
}

#Preview("Lock Screen", as: .content, using: LyktaActivity(id: UUID(), name: "demo")) {
    LyktaLiveActivity()
} contentStates: {
    try! LyktaActivity.ContentState(title: Demo.title, layout: Demo.layout.filled(with: Demo.data(start: .now)).json)
}

#Preview("Dynamic Island", as: .dynamicIsland(.expanded), using: LyktaActivity(id: UUID(), name: "demo")) {
    LyktaLiveActivity()
} contentStates: {
    try! LyktaActivity.ContentState(title: Demo.title, layout: Demo.layout.filled(with: Demo.data(start: .now)).json)
}
