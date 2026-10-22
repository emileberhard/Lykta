import LyktaCore
import SwiftUI
import UIKit

struct HomeView: View {
    let model: Model
    @State private var examples: [Example] = []
    @State private var isConfirmingReset = false
    @Namespace private var transition
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Header()
                content
                ExampleRows(examples: examples, transition: transition)
            }
            .listSectionSpacing(.compact)
            .navigationLinkIndicatorVisibility(.hidden)
            .navigationDestination(for: Example.ID.self) { id in
                if let example = examples.first(where: { $0.id == id }) {
                    ExampleView(example: example, model: model)
                        .navigationTransition(.zoom(sourceID: id, in: transition))
                }
            }
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
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            examples = await Example.bundled(at: .now)
        }
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

struct LockScreenCard: View {
    private static let maximumHeight: CGFloat = 160
    private static let textSizes = DynamicTypeSize.large ... .xxxLarge

    let state: LyktaActivity.ContentState
    let activity: UUID?
    let isStale: Bool

    var body: some View {
        LockScreenView(state: state, activity: activity, isStale: isStale)
            .frame(maxWidth: .infinity, maxHeight: Self.maximumHeight)
            .clipped()
            .dynamicTypeSize(Self.textSizes)
    }
}

extension View {
    func lockScreenRow(_ state: LyktaActivity.ContentState) -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(state.layout?.background?.value)
    }
}

struct ActivitiesOffNotice: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Notice(Label("Live Activities Are Off", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor),
               action: "Turn On") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
    }
}

struct Problem: View {
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

private struct Notice<Message: View>: View {
    let message: Message
    let action: LocalizedStringKey
    let perform: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ message: Message, action: LocalizedStringKey, perform: @escaping () -> Void) {
        self.message = message
        self.action = action
        self.perform = perform
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            message.frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
                .buttonStyle(.bordered)
                .tint(.primary)
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

    var body: some View {
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
        .controlSize(.large)
        .buttonSizing(.flexible)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .padding(.horizontal)
        .disabled(!model.phase.isReady)
        .sensoryFeedback(.success, trigger: copies)
        .task(id: copies) {
            guard copies > 0 else { return }
            withAnimation { isShowingCopied = true }
            guard (try? await Task.sleep(for: .seconds(2))) != nil else { return }
            withAnimation { isShowingCopied = false }
        }
    }
}

extension Model.Phase {
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
