import SwiftUI

@main
struct LyktaApp: App {
    @State private var model = Model()

    var body: some Scene {
        WindowGroup {
            HomeView(model: model)
        }
    }
}
