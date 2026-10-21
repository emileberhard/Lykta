import SwiftUI
import UIKit

struct HomeView: View {
    let model: Model
    @State private var copies = 0
    @State private var demos = 0
    @State private var isSendingDemo = false
    @State private var isConfirmingReset = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Lykta")
                .toolbar {
                    Menu("More", systemImage: "ellipsis") {
                        Button("Reset", systemImage: "arrow.counterclockwise", role: .destructive) { isConfirmingReset = true }
                    }
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
        case .connecting:
            ProgressView()
        case let .failed(message):
            ContentUnavailableView {
                Label("Gateway Unavailable", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.start() }
            }
        case .ready:
            List {
                if !model.areActivitiesEnabled {
                    Button("Turn On Live Activities", systemImage: "exclamationmark.triangle") {
                        openURL(URL(string: UIApplication.openSettingsURLString)!)
                    }
                }
                Section {
                    Button("Copy Setup for Your Agent", systemImage: "doc.on.doc") {
                        model.copySetup()
                        copies += 1
                    }
                    Button {
                        Task {
                            isSendingDemo = true
                            if await model.sendDemo() { demos += 1 }
                            isSendingDemo = false
                        }
                    } label: {
                        Label {
                            Text("Send Demo")
                        } icon: {
                            if isSendingDemo { ProgressView() } else { Image(systemName: "sparkles") }
                        }
                    }
                    .disabled(isSendingDemo)
                }
                if !model.activities.isEmpty {
                    Section("Live") {
                        ForEach(model.activities, id: \.id) { Text($0.attributes.name) }
                    }
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                }
            }
            .sensoryFeedback(.success, trigger: copies)
            .sensoryFeedback(.success, trigger: demos)
        }
    }
}
