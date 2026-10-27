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
                AppView(model: model)
            }
            #else
            AppView(model: model)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in model.sceneChanged(to: phase) }
    }
}

private struct AppView: View {
    let model: Model
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isOnboarding {
                Onboarding(model: model)
                    .transition(transition)
            } else {
                HomeView(model: model)
                    .transition(transition)
            }
        }
        .animation(.smooth(duration: 0.6), value: model.isOnboarding)
        .onOpenURL { openURL($0) }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : AnyTransition(.blurReplace)
    }
}
