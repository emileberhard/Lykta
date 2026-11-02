import LyktaCore
import SwiftUI

struct LockScreenCard: View {
    static let textSizes = DynamicTypeSize.large ... .xxxLarge

    let state: LyktaActivity.ContentState
    let activity: UUID?
    let isStale: Bool

    var body: some View {
        let capped = CappedHeight(maximum: 160)
        capped {
            LockScreenView(state: state, activity: activity, isStale: isStale)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .dynamicTypeSize(Self.textSizes)
    }
}

struct CappedHeight: SwiftUI.Layout {
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maximum))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

extension View {
    func lockScreenRow(_ state: LyktaActivity.ContentState) -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(state.layout?.background?.value)
    }
}
