import SwiftUI

@main
struct RenderApp: App {
    var body: some Scene {
        WindowGroup {
            RenderHost(output: .standardOutput)
        }
    }
}
