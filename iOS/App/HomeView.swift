import LyktaCore
import SwiftUI

struct HomeView: View {
    let model: Model
    @State private var isConfirmingReset = false
    @State private var details: LiveActivity?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Header()
                content
            }
            .listSectionSpacing(.compact)
            .navigationDestination(for: Gallery.Route.self) { _ in
                Gallery(model: model)
            }
            .safeAreaBar(edge: .bottom) {
                Actions(model: model)
            }
            .toolbar {
                ToolbarOverflowMenu {
                    Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) { isConfirmingReset = true }
                        .disabled(!model.isRegistered)
                }
            }
            .confirmationDialog("Reset Lykta?", isPresented: $isConfirmingReset) {
                Button("Reset", role: .destructive) {
                    Task { await model.reset() }
                }
            } message: {
                Text("Ends every activity, deletes this phone from the gateway and replaces the agent token.")
            }
            .sheet(item: $details) { activity in
                ActivityDetails(model: model, id: activity.id)
            }
        }
        .overlay {
            ZStack {
                if model.showsLockHint {
                    LockHint(dismiss: model.dismissLockHint)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: model.showsLockHint ? 0.45 : 0.25), value: model.showsLockHint)
        }
        .onOpenURL { openURL($0) }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.loadExamples()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .unconfigured:
            ContentUnavailableView("No Gateway", systemImage: "network.slash",
                                   description: Text("Set LYKTA_GATEWAY_HOST in iOS/Config/Local.xcconfig."))
                .listRowBackground(Color.clear)
        case .connecting:
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        case let .failed(message):
            Section {
                Notice(Problem(message), action: "Try Again") { model.start() }
            }
        case .ready:
            if !model.areActivitiesEnabled {
                Section { ActivitiesOffNotice() }
            }
            if let notifications = model.notifications {
                NotificationsNotice(settings: notifications) {
                    await model.allowNotifications()
                }
            }
            if let error = model.error {
                Section { Problem(error) }
            }
            ForEach(model.activities) { activity in
                ActivitySection(activity: activity, showDetails: { details = activity }, end: { Task { await model.end(activity) } })
            }
        }
    }
}

private struct Header: View {
    var body: some View {
        VStack(spacing: 6) {
            Lights()
                .frame(height: 104)
                .padding(.bottom, 18)
            Text("Lykta")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Your agents on the Lock Screen")
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

private struct Actions: View {
    let model: Model

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 10) {
                ActionButton(title: "Copy Agent Setup", systemImage: "doc.on.doc", done: "Copied") {
                    await model.copySetup()
                }
                .disabled(!model.phase.isReady)

                NavigationLink(value: Gallery.Route()) {
                    Label("Examples", systemImage: "rectangle.stack")
                }
                .accessibilityShowsLargeContentViewer()
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .buttonSizing(.flexible)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding(.horizontal)
    }
}

#if DEBUG
#Preview("Live") {
    HomeView(model: .preview(.ready, activities: [.deploy, .deploy(id: "release", state: .stale, isEnding: false),
                                                  .deploy(id: "rollback", state: .active, isEnding: true)]))
}

extension LiveActivity {
    static let deploy = deploy(id: "deploy", state: .active, isEnding: false)

    static func deploy(id: String, state: ObservedState, isEnding: Bool) -> LiveActivity {
        let attributes = LyktaActivity(id: UUID(), name: id)
        let started = Date.now.addingTimeInterval(-40 * 60)
        return LiveActivity(id: id, attributes: attributes, content: try! LyktaActivity.ContentState(title: "Deploying the gateway", layout: Array(#"""
            {
              "lockScreen": {
                "hstack": [
                  {"symbol": "shippingbox.fill", "modifiers": [{"font": "title2"}]},
                  {
                    "vstack": [
                      {"text": "Deploying the gateway", "modifiers": [{"font": "headline"}]},
                      {"text": "Health checks · 3 of 4", "modifiers": [{"font": "subheadline"}, {"opacity": 0.8}]}
                    ],
                    "alignment": "leading",
                    "spacing": 2
                  },
                  {"spacer": true}
                ],
                "spacing": 12,
                "modifiers": [{"foreground": "white"}, {"padding": 16}]
              },
              "compactLeading": {"symbol": "shippingbox.fill"},
              "compactTrailing": {"text": "3/4"},
              "minimal": {"symbol": "shippingbox.fill"},
              "background": "indigo"
            }
            """#.utf8)), state: state,
            times: ActivityTimes(id: attributes.id, startedAt: started, updatedAt: .now.addingTimeInterval(-120), endsAt: started.addingTimeInterval(8 * 3600)),
            isEnding: isEnding)
    }
}

#Preview("Empty") {
    HomeView(model: .preview(.ready))
}

#Preview("Live Activities Off") {
    HomeView(model: .preview(.ready, areActivitiesEnabled: false))
}

#Preview("Notifications Not Allowed Yet") {
    HomeView(model: .preview(.ready, notifications: NotificationSettings(authorization: .notDetermined, alertStyle: .banner, registration: .pending)))
}

#Preview("Notifications Off") {
    HomeView(model: .preview(.ready, notifications: NotificationSettings(authorization: .denied, alertStyle: .banner, registration: .pending)))
}

#Preview("Temporary Banners") {
    HomeView(model: .preview(.ready, notifications: NotificationSettings(authorization: .authorized, alertStyle: .banner, registration: .pending)))
}

#Preview("No Notification Token") {
    HomeView(model: .preview(.ready, notifications: NotificationSettings(
        authorization: .authorized, alertStyle: .alert,
        registration: .failed("no valid “aps-environment” entitlement string found for application"))))
}

#Preview("Unavailable") {
    HomeView(model: .preview(.failed("The Internet connection appears to be offline.")))
}
#endif
