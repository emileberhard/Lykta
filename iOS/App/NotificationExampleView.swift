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
                NotificationsNotice(settings: notifications) {
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
            ActionButton(title: "Send Notification", systemImage: "bell.badge", working: "Sending…", done: "Sent") {
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

extension NotificationBanner {
    init(example: NotificationExample) {
        self.init(sender: example.sender, text: example.body, avatar: example.avatar, image: example.image)
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
