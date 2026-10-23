import LyktaCore
import SwiftUI

struct LockScreenCard: View {
    private static let maximumHeight: CGFloat = 160
    static let textSizes = DynamicTypeSize.large ... .xxxLarge

    let state: LyktaActivity.ContentState
    let activity: UUID?
    let isStale: Bool

    var body: some View {
        LockScreenView(state: state, activity: activity, isStale: isStale)
            .frame(maxWidth: .infinity, maxHeight: Self.maximumHeight)
            .clipped()
            .dynamicTypeSize(Self.textSizes)
    }
}

extension View {
    func lockScreenRow(_ state: LyktaActivity.ContentState) -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(state.layout?.background?.value)
    }
}
