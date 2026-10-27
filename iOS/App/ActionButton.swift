import SwiftUI

struct ActionButton: View {
    private enum Phase { case ready, working, done }

    let title: LocalizedStringKey
    let systemImage: String
    let working: LocalizedStringKey
    let done: LocalizedStringKey
    let action: () async -> Bool
    @State private var phase = Phase.ready

    var body: some View {
        Button {
            Task {
                phase = .working
                phase = await action() ? .done : .ready
            }
        } label: {
            Label(title, systemImage: systemImage)
                .shown(phase == .ready)
                .overlay {
                    Label { Text(working) } icon: { ProgressView() }
                        .shown(phase == .working)
                    Label(done, systemImage: "checkmark")
                        .shown(phase == .done)
                }
                .animation(.easeOut(duration: 0.15), value: phase)
        }
        .disabled(phase == .working)
        .accessibilityShowsLargeContentViewer()
        .sensoryFeedback(.success, trigger: phase) { $1 == .done }
        .task(id: phase) {
            guard phase == .done, (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            phase = .ready
        }
    }
}

private extension View {
    func shown(_ isShown: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .accessibilityHidden(!isShown)
    }
}
