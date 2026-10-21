import SwiftUI

@main
struct LyktaApp: App {
    private let model = Model()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        model.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(to: phase) }
    }
}
