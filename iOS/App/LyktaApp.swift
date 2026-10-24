import AppIntents
import SwiftUI

@main
struct LyktaApp: App {
    private let model = Model()
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        model.start()
        let model = model
        AppDependencyManager.shared.add(dependency: ActionSender { try await model.send($0) })
    }

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(to: phase) }
    }
}
