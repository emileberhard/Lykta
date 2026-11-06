import SwiftUI
import UIKit

struct HandoffView: View {
    let model: Model
    let handoff: Model.Handoff
    @State private var isCopied = false

    var body: some View {
        Group {
            switch handoff.state {
            case .opening:
                DelayedProgress()
            case .opened:
                Color.clear
            case .failed:
                ContentUnavailableView {
                    Label("Couldn’t Open Link", systemImage: "link")
                } description: {
                    Text(handoff.link.absoluteString)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } actions: {
                    Button("Try Again") { model.retryHandoff() }
                        .buttonStyle(.borderedProminent)
                    Button(isCopied ? "Copied" : "Copy Link", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.url = handoff.link
                        isCopied = true
                    }
                    Button("Open Lykta") { model.leaveHandoff() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: handoff) { await model.openHandoff() }
    }
}

private struct DelayedProgress: View {
    @State private var isShown = false

    var body: some View {
        ProgressView()
            .opacity(isShown ? 1 : 0)
            .onAppear { withAnimation(.easeIn.delay(1)) { isShown = true } }
    }
}
