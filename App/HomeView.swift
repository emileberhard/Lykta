import LyktaCore
import SwiftUI
import UIKit

struct HomeView: View {
    let model: Model
    @State private var isConfirmingReset = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Header()
                content
            }
            .listSectionSpacing(.compact)
            .safeAreaBar(edge: .bottom) {
                if model.phase.isConfigured {
                    Actions(model: model)
                }
            }
            .toolbar {
                Menu("More", systemImage: "ellipsis") {
                    Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) { isConfirmingReset = true }
                }
                .disabled(!model.phase.isReady)
            }
            .confirmationDialog("Reset Lykta?", isPresented: $isConfirmingReset) {
                Button("Reset", role: .destructive) {
                    Task {
                        await model.reset()
                        model.start()
                    }
                }
            } message: {
                Text("Ends every activity, deletes this phone from the gateway and replaces the agent token.")
            }
        }
        .onOpenURL { openURL($0) }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .unconfigured:
            ContentUnavailableView("No Gateway", systemImage: "network.slash",
                                   description: Text("Set LYKTA_GATEWAY_HOST in Config/Local.xcconfig."))
                .listRowBackground(Color.clear)
        case .connecting:
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
        case let .failed(message):
            Section {
                HStack {
                    Problem(message)
                    Spacer(minLength: 12)
                    Button("Try Again") { model.start() }
                        .buttonStyle(.bordered)
                        .tint(.primary)
                }
            }
        case .ready:
            if !model.areActivitiesEnabled {
                Section {
                    HStack {
                        Label("Live Activities Are Off", systemImage: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                        Spacer(minLength: 12)
                        Button("Turn On") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                            .buttonStyle(.bordered)
                            .tint(.primary)
                    }
                }
            }
            if let error = model.error {
                Section { Problem(error) }
            }
            ForEach(model.activities) { activity in
                Section {
                    LockScreenCard(activity: activity)
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

private struct LockScreenCard: View {
    private static let maximumHeight: CGFloat = 160
    private static let textSizes = DynamicTypeSize.large ... .xxxLarge

    let activity: LiveActivity

    var body: some View {
        LockScreenView(state: activity.content, isStale: activity.state == .stale)
            .frame(maxWidth: .infinity, maxHeight: Self.maximumHeight)
            .clipped()
            .dynamicTypeSize(Self.textSizes)
            .listRowInsets(EdgeInsets())
            .listRowBackground(activity.content.layout?.background?.value)
    }
}

private struct Problem: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
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
    @State private var copies = 0
    @State private var isShowingCopied = false
    @State private var demos = 0
    @State private var isSendingDemo = false

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 10) {
                Button {
                    model.copySetup()
                    copies += 1
                } label: {
                    Label(isShowingCopied ? "Copied" : "Copy Agent Setup",
                          systemImage: isShowingCopied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(Color(.systemBackground))
                }
                .buttonStyle(.glassProminent)
                .tint(.primary)

                Button {
                    Task {
                        isSendingDemo = true
                        if await model.sendDemo() { demos += 1 }
                        isSendingDemo = false
                    }
                } label: {
                    Label {
                        Text(isSendingDemo ? "Sending…" : "Send Demo")
                    } icon: {
                        if isSendingDemo {
                            ProgressView()
                        } else {
                            Image(systemName: "sparkles")
                                .symbolEffect(.bounce, value: demos)
                        }
                    }
                }
                .buttonStyle(.glass)
                .disabled(isSendingDemo)
            }
            .controlSize(.large)
            .buttonSizing(.flexible)
        }
        .padding(.horizontal)
        .disabled(!model.phase.isReady)
        .sensoryFeedback(.success, trigger: copies)
        .sensoryFeedback(.success, trigger: demos)
        .task(id: copies) {
            guard copies > 0 else { return }
            withAnimation { isShowingCopied = true }
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            withAnimation { isShowingCopied = false }
        }
    }
}

private extension Model.Phase {
    var isReady: Bool {
        if case .ready = self { true } else { false }
    }

    var isConfigured: Bool {
        if case .unconfigured = self { false } else { true }
    }
}

#if DEBUG
#Preview("Live") {
    HomeView(model: .preview(.ready, activities: [
        LiveActivity(id: "1", content: try! LyktaActivity.ContentState(title: Demo.title, layout: Demo.layout.filled(with: Demo.data(start: .now)).json),
                     state: .active),
        LiveActivity(id: "2", content: try! LyktaActivity.ContentState(title: "Deploying the gateway", layout: Array(#"""
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
