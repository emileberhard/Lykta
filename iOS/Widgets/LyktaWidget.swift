import LyktaCore
import SwiftUI
import WidgetKit

struct LyktaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetSelection.kind, intent: WidgetSelection.self, provider: WidgetProvider()) { entry in
            WidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Lykta")
        .description("Shows a widget an agent made for this iPhone.")
        .supportedFamilies([.systemSmall])
        .promptsForUserConfiguration()
        .pushHandler(WidgetPushes.self)
    }
}

struct WidgetEntryView: View {
    let entry: WidgetEntry

    var body: some View {
        switch entry.state {
        case let .content(layout, family, isStale):
            WidgetView(layout: layout, family: family, isStale: isStale)
                .containerBackground(for: .widget) { WidgetBackground(background: layout.background, isStale: isStale) }
        case let .unreachable(title):
            Notice(title: title, detail: "Can’t reach the gateway", symbol: "wifi.exclamationmark")
        case let .removed(title):
            Notice(title: title, detail: "Removed", symbol: "xmark.circle")
        case let .updateApp(title):
            Notice(title: title, detail: "Update Lykta to show this widget.", symbol: "arrow.down.app")
        case let .unsupported(title):
            Notice(title: title, detail: "Not made for this size", symbol: "rectangle.dashed")
        case let .notLoaded(title):
            Notice(title: title, detail: "Loads once added", symbol: "square.dashed")
        case .signedOut:
            Notice(title: "Lykta", detail: "Open Lykta to connect it to your gateway.", symbol: "person.crop.circle.badge.questionmark")
        case .choose:
            Notice(title: "Lykta", detail: "Choose a widget", symbol: "square.dashed")
        }
    }
}

private struct Notice: View {
    let title: String
    let detail: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(.background, for: .widget)
    }
}
