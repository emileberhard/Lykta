import LyktaCore
import SwiftUI

struct AvatarView: View {
    static let size: CGFloat = 64
    let node: Node

    var body: some View {
        NodeView(node)
            .frame(width: Self.size, height: Self.size)
            .font(.body)
            .dynamicTypeSize(.large)
            .environment(\.colorScheme, .light)
    }
}
