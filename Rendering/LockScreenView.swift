import LyktaCore
import SwiftUI
import WidgetKit

struct LockScreenView: View {
    let state: LyktaActivity.ContentState
    let activity: UUID
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
                Root(node: small, activity: activity, isStale: isStale)
            } else if family == .small {
                HStack {
                    Root(node: layout.compactLeading, activity: activity, isStale: isStale)
                    Spacer(minLength: 4)
                    Root(node: layout.compactTrailing, activity: activity, isStale: isStale)
                }
                .compact()
                .padding(12)
            } else {
                Root(node: layout.lockScreen, activity: activity, isStale: isStale)
            }
        } else {
            Fallback(title: state.title).padding(16)
        }
    }
}

struct Root: View {
    let node: Node?
    let activity: UUID
    let isStale: Bool

    var body: some View {
        if let node {
            NodeView(node)
                .environment(\.isActivityStale, isStale)
                .environment(\.activityID, activity)
        }
    }
}

struct Fallback: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text("Update Lykta to show this activity.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func compact() -> some View {
        lineLimit(1).minimumScaleFactor(0.5)
    }
}
