import LyktaCore
import SwiftUI

struct NotificationBanner: View {
    let sender: String
    let text: String
    let avatar: NotificationAvatar.Source
    let image: Data?
    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            NotificationAvatar(avatar: avatar)
                .scaleEffect(avatarSize / AvatarView.size)
                .frame(width: avatarSize, height: avatarSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(sender)
                    .fontWeight(.semibold)
                Text(text)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let image {
                Picture(data: image)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
        }
    }
}

struct NotificationAvatar: View {
    nonisolated enum Source: Sendable {
        case picture(Data), drawing(Node)
    }

    let avatar: Source

    var body: some View {
        Group {
            switch avatar {
            case let .drawing(node): AvatarView(node: node)
            case let .picture(data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
        }
        .frame(width: AvatarView.size, height: AvatarView.size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct Picture: View {
    let data: Data
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
    }
}
