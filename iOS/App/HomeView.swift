import LyktaCore
import SwiftUI

struct HomeView: View {
    let model: Model
    @State private var isConfirmingReset = false
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
            if let error = model.error {
                Section { Problem(error) }
            }
            ForEach(model.activities) { activity in
                Section {
                    LockScreenCard(state: activity.content, activity: activity.attributes.id, isStale: activity.state == .stale)
                        .lockScreenRow(activity.content)
                } footer: {
                    if let status = activity.status {
                        Text(status)
                    }
                }
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

private extension LiveActivity {
    var status: LocalizedStringResource? {
        switch state {
        case .active, .stale: nil
        case .pending: "Starting"
        case .ended: "Ended"
        case .dismissed: "Removed from the Lock Screen"
        case .unknown: "Unknown"
        }
    }
}

private struct Actions: View {
    let model: Model

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 10) {
                ActionButton(title: "Copy Agent Setup", systemImage: "doc.on.doc", done: "Copied") {
                    model.copySetup()
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
    HomeView(model: .preview(.ready, activities: [
        LiveActivity(id: "1", attributes: LyktaActivity(id: UUID(), name: "deploy"), content: try! LyktaActivity.ContentState(title: "Deploying the gateway", layout: Array(#"""
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
            """#.utf8)), state: .stale),
    ]))
}

#Preview("Empty") {
    HomeView(model: .preview(.ready))
}

#Preview("Live Activities Off") {
    HomeView(model: .preview(.ready, areActivitiesEnabled: false))
}

#Preview("Unavailable") {
    HomeView(model: .preview(.failed("The Internet connection appears to be offline.")))
}
#endif
