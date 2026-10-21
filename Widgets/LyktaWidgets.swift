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
