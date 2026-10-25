import AppIntents
import SwiftUI

@main
struct LyktaApp: App {
    private let model = Model()
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        if Capture.directory != nil { return }
        #endif
        model.start()
        let model = model
        AppDependencyManager.shared.add(dependency: ActionSender { try await model.send($0) })
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let directory = Capture.directory {
                CaptureView(directory: directory)
            } else {
                HomeView(model: model)
            }
            #else
            HomeView(model: model)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(to: phase) }
    }
}
