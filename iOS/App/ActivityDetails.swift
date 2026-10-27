import LyktaCore
import SwiftUI

struct ActivityDetails: View {
    let model: Model
    let id: LiveActivity.ID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let activity = model.activities.first { $0.id == id }
        NavigationStack {
            List {
                if let activity {
                    Section {
                        LockScreenCard(state: activity.content, activity: activity.attributes.id, isStale: activity.state == .stale)
                            .lockScreenRow(activity.content)
                    }
                    ActivityFacts(status: ActivityStatus(activity), times: activity.times, name: activity.attributes.name)
                    if activity.canEnd {
                        Section {
                            Button("End Activity", role: .destructive) {
                                Task { await model.end(activity) }
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle(activity?.content.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button(role: .close) { dismiss() }
            }
        }
        .onChange(of: activity == nil, initial: true) { _, isGone in
            if isGone { dismiss() }
        }
    }
}

private struct ActivityFacts: View {
    let status: ActivityStatus
    let times: ActivityTimes?
    let name: String

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    StatusDot(color: status.color)
                    Text(status.title)
                }
            }
            if let times {
                if let updatedAt = times.updatedAt {
                    LabeledContent("Updated") {
                        Text(.currentDate, format: .reference(to: updatedAt))
                    }
                }
                LabeledContent("Started") {
                    Text(times.startedAt, format: .dateTime.hour().minute())
                }
                LabeledContent([.ended, .removed].contains(status) ? "Ended" : "Ends") {
                    Text(times.endsAt, format: .dateTime.hour().minute())
                }
            }
            LabeledContent("Name") {
                Text(name)
                    .monospaced()
                    .textSelection(.enabled)
            }
        }
    }
}

#if DEBUG
#Preview {
    ActivityDetails(model: .preview(.ready, activities: [.deploy]), id: LiveActivity.deploy.id)
}
#endif
