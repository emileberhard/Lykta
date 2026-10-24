import SwiftUI

struct NotificationExampleView: View {
    let example: NotificationExample
    let model: Model

    var body: some View {
        List {
            Section {
                NotificationBanner(example: example)
                    .accessibilityElement(children: .combine)
            }
            if let image = example.image.flatMap(UIImage.init(data:)) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .listRowInsets(EdgeInsets())
                        .accessibilityHidden(true)
                }
            }
            if model.phase.isReady, let notifications = model.notifications {
                NotificationsNotice(authorization: notifications.authorization, alertStyle: notifications.alertStyle) {
                    await model.allowNotifications()
                }
            }
            if let error = model.error {
                Section { Problem(error) }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(example.sender)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .bottom) {
            ActionButton(title: "Send Notification", systemImage: "bell.badge", done: "Sent") {
                await model.send(example)
            }
            .buttonStyle(.glassProminent)
            .tint(.primary)
            .foregroundStyle(Color(.systemBackground))
            .controlSize(.large)
            .buttonSizing(.flexible)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .disabled(!model.phase.isReady)
            .padding(.horizontal)
        }
    }
}

struct NotificationBanner: View {
    let example: NotificationExample

    var body: some View {
        HStack(spacing: 12) {
            Picture(data: example.avatar)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(example.sender)
                    .fontWeight(.semibold)
                Text(example.body)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let image = example.image {
                Picture(data: image)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
        }
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

#if DEBUG
#Preview("Notification", traits: .modifier(BundledExamples())) {
    @Previewable @Environment(Model.self) var model
    NavigationStack {
        NotificationExampleView(example: model.notificationExamples.first { $0.id == "print-finished" }!, model: model)
    }
}
#endif
