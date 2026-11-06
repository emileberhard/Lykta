import LyktaCore
import SwiftUI

struct LockScreenCard: View {
    static let textSizes = DynamicTypeSize.large ... .xxxLarge
    static let maximumHeight: CGFloat = 160

    let state: LyktaActivity.ContentState
    let activity: UUID?
    let isStale: Bool

    var body: some View {
        CappedHeight(maximum: Self.maximumHeight) {
            LockScreenView(state: state, activity: activity, isStale: isStale)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .dynamicTypeSize(Self.textSizes)
    }
}

private struct CappedHeight: SwiftUI.Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let measured = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? measured.width, height: min(measured.height, maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    func lockScreenRow(_ state: LyktaActivity.ContentState) -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(state.layout?.background?.value)
    }
}
