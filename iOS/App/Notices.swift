import LyktaCore
import SwiftUI
import UIKit

struct ActivitiesOffNotice: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Notice(Label("Live Activities Are Off", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor),
               action: "Turn On") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
    }
}

struct NotificationsNotice: View {
    let authorization: NotificationSettings.Authorization
    let alertStyle: NotificationSettings.AlertStyle
    let allow: () async -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch (authorization, alertStyle) {
        case (.notDetermined, _):
            Section {
                Notice(Label("Agent Notifications", systemImage: "bell.badge.fill"), action: "Allow") { Task { await allow() } }
            }
        case (.denied, _):
            Section {
                Notice(Label("Notifications Are Off", systemImage: "bell.slash.fill"), action: "Turn On") { openSettings() }
            }
        case (_, .banner):
            Section {
                Notice(Label("Temporary Banners Cut Sounds Short", systemImage: "bell.badge.waveform.fill"), action: "Change") { openSettings() }
            }
        default:
            EmptyView()
        }
    }

    private func openSettings() {
        openURL(URL(string: UIApplication.openNotificationSettingsURLString)!)
    }
}

struct Problem: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

struct Notice<Message: View>: View {
    let message: Message
    let action: LocalizedStringKey
    let perform: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ message: Message, action: LocalizedStringKey, perform: @escaping () -> Void) {
        self.message = message
        self.action = action
        self.perform = perform
    }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            message.frame(maxWidth: .infinity, alignment: .leading)
            Button(action, action: perform)
                .buttonStyle(.bordered)
                .tint(.primary)
        }
    }
}
