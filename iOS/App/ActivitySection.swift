import LyktaCore
import SwiftUI

struct ActivitySection: View {
    let activity: LiveActivity
    let isEnding: Bool
    let showDetails: () -> Void
    let end: () -> Void

    var body: some View {
        Section {
            LockScreenCard(state: activity.content, activity: activity.attributes.id, isStale: activity.state == .stale)
                .lockScreenRow(activity.content)
        } header: {
            ActivityHeader(title: activity.content.title, status: ActivityStatus(activity.state, isEnding: isEnding),
                           updatedAt: activity.times?.updatedAt, canEnd: activity.isEndable && !isEnding,
                           showDetails: showDetails, end: end)
        }
    }
}

enum ActivityStatus: Equatable {
    case starting, live, outOfDate, ending, ended, removed, unknown

    init(_ state: ObservedState, isEnding: Bool) {
        self = switch (state, isEnding) {
        case (.pending, false): .starting
        case (.active, false): .live
        case (.stale, false): .outOfDate
        case (.pending, true), (.active, true), (.stale, true): .ending
        case (.ended, _): .ended
        case (.dismissed, _): .removed
        case (.unknown, _): .unknown
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .starting: "Starting"
        case .live: "Live"
        case .outOfDate: "Out of Date"
        case .ending: "Ending"
        case .ended: "Ended"
        case .removed: "Removed"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .starting: .blue
        case .live: .green
        case .outOfDate, .ending: .orange
        case .ended, .removed, .unknown: .gray
        }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

private struct ActivityHeader: View {
    let title: String
    let status: ActivityStatus
    let updatedAt: Date?
    let canEnd: Bool
    let showDetails: () -> Void
    let end: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text("\(Text(title).fontWeight(.semibold).foregroundStyle(Color.primary))  \(recency)")
            } icon: {
                StatusDot(color: status.color)
            }
            .labelIconToTitleSpacing(6)
            Spacer(minLength: 0)
            ZStack {
                if status == .ending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Menu {
                        Button("Details", systemImage: "info.circle", action: showDetails)
                        if canEnd {
                            Button("End Activity", systemImage: "xmark.circle", role: .destructive, action: end)
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .fontWeight(.semibold)
                            .frame(width: 28, height: 28)
                            .background(.fill.tertiary, in: .circle)
                    }
                    .tint(.primary)
                }
            }
            .frame(width: 28, height: 28)
        }
        .font(.subheadline)
        .textCase(nil)
    }

    private var recency: Text {
        if status == .live, let updatedAt {
            Text(.currentDate, format: .reference(to: updatedAt))
        } else {
            Text(status.title)
        }
    }
}

