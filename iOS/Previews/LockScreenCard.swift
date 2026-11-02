import LyktaCore
import SwiftUI

struct LockScreenCard: View {
    static let textSizes = DynamicTypeSize.large ... .xxxLarge
    static let maximumHeight: CGFloat = 160

    let state: LyktaActivity.ContentState
    let activity: UUID?
    let isStale: Bool

    var body: some View {
        let capped = CappedHeight(maximum: Self.maximumHeight, measurement: .idealSize)
        capped {
            LockScreenView(state: state, activity: activity, isStale: isStale)
        }
        .frame(maxWidth: .infinity)
        .clipped()
        .dynamicTypeSize(Self.textSizes)
    }
}

struct CappedHeight: SwiftUI.Layout {
    enum Measurement {
        case idealSize
        case proposedWidth

        func proposal(for width: CGFloat?) -> ProposedViewSize {
            switch self {
            case .idealSize: .unspecified
            case .proposedWidth: ProposedViewSize(width: width, height: nil)
            }
        }
    }

    let maximum: CGFloat
    let measurement: Measurement

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let measured = content.sizeThatFits(measurement.proposal(for: proposal.width))
        return CGSize(width: proposal.width ?? measured.width, height: min(measured.height, maximum))
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
