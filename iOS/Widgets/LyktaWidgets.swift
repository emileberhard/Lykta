import LyktaCore
import SwiftUI
import WidgetKit

@main
struct LyktaWidgets: WidgetBundle {
    var body: some Widget {
        LyktaLiveActivity()
        LyktaWidget()
    }
}

struct LyktaLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyktaActivity.self) { context in
            LockScreenView(state: context.state, activity: context.attributes.id, isStale: context.isStale)
        } dynamicIsland: { context in
            let layout = context.state.layout
            let isStale = context.isStale
            let activity = context.attributes.id
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Root(node: layout?.expanded?.leading, target: .activity(activity), isStale: isStale).dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Root(node: layout?.expanded?.trailing, target: .activity(activity), isStale: isStale).dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.center) {
                    Root(node: layout?.expanded?.center, target: .activity(activity), isStale: isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if layout == nil {
                        Fallback(title: context.state.title)
                    } else {
                        Root(node: layout?.expanded?.bottom, target: .activity(activity), isStale: isStale)
                    }
                }
            } compactLeading: {
                Root(node: layout?.compactLeading, target: .activity(activity), isStale: isStale).compact()
            } compactTrailing: {
                if layout == nil {
                    Text(context.state.title).compact()
                } else {
                    Root(node: layout?.compactTrailing, target: .activity(activity), isStale: isStale).compact()
                }
            } minimal: {
                Root(node: layout?.minimal, target: .activity(activity), isStale: isStale).compact()
            }
            .keylineTint(layout?.keyline?.value)
            .widgetURL(layout?.link)
        }
        .supplementalActivityFamilies([.small])
    }
}
