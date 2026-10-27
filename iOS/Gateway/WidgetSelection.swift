import AppIntents
import Foundation
import LyktaCore
import WidgetKit

struct WidgetSelection: WidgetConfigurationIntent {
    nonisolated static let kind = "Lykta"
    static let title: LocalizedStringResource = "Choose a Widget"
    static let description = IntentDescription("Shows a widget an agent made for this iPhone.")

    @Parameter(title: "Widget") var widget: WidgetEntity?

    nonisolated static func places(in configurations: [WidgetInfo]) -> [WidgetPlace] {
        configurations.compactMap { info in
            guard info.kind == kind, let family = WidgetLayout.Family(info.family),
                  let widget = info.widgetConfigurationIntent(of: WidgetSelection.self)?.widget else { return nil }
            return WidgetPlace(widget: widget.id, family: family)
        }
    }
}

nonisolated struct WidgetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget"
    static let defaultQuery = WidgetQuery()

    let id: UUID
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

nonisolated struct WidgetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetEntity] {
        let titles = Dictionary((try? WidgetCache.titles())?.map { ($0.id, $0.title) } ?? []) { first, _ in first }
        return identifiers.map { WidgetEntity(id: $0, title: titles[$0] ?? String(localized: "Widget")) }
    }

    func suggestedEntities() async throws -> [WidgetEntity] {
        try await listed()
    }

    private func listed() async throws -> [WidgetEntity] {
        guard let gateway = GatewayClient.configured(timeout: 10), let credential = try KeychainItem.widget.load() else {
            throw AppError(status: nil, errorDescription: String(localized: "Open Lykta to connect it to your gateway."))
        }
        do {
            let widgets = try await gateway.widgets(widgetToken: credential.widgetToken)
            guard (try? WidgetCache.remember(widgets, listedWith: credential, at: .now)) != false else {
                throw AppError(status: nil, errorDescription: String(localized: "Open Lykta to connect it to your gateway."))
            }
            return widgets.map { WidgetEntity(id: $0.id, title: $0.title) }
        } catch let error as AppError where error.status == 401 {
            throw AppError(status: nil, errorDescription: String(localized: "Open Lykta to connect it to your gateway."))
        } catch {
            let cached = try WidgetCache.titles()
            guard !cached.isEmpty else { throw error }
            return cached.map { WidgetEntity(id: $0.id, title: $0.title) }
        }
    }
}

nonisolated extension WidgetLayout.Family {
    init?(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .systemSmall
        case .systemMedium: self = .systemMedium
        case .systemLarge: self = .systemLarge
        case .accessoryCircular: self = .accessoryCircular
        case .accessoryRectangular: self = .accessoryRectangular
        case .accessoryInline: self = .accessoryInline
        default: return nil
        }
    }
}
