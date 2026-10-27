import Foundation
import LyktaCore
import WidgetKit

nonisolated struct WidgetEntry: TimelineEntry {
    enum State: Sendable {
        case content(WidgetLayout, WidgetLayout.Family, isStale: Bool)
        case unreachable(title: String)
        case removed(title: String)
        case updateApp(title: String)
        case unsupported(title: String)
        case signedOut
        case choose
    }

    let date: Date
    let state: State
}

nonisolated struct WidgetProvider: AppIntentTimelineProvider {
    private static let reconciliation: TimeInterval = 3 * 3600

    private static let example: WidgetLayout? = {
        struct Body: Decodable {
            let layout: JSONValue
            let data: JSONValue
        }
        guard let file = Bundle.main.url(forResource: "steps-widget", withExtension: "json"),
              let body = try? JSONDecoder().decode(Body.self, from: Data(contentsOf: file)) else { return nil }
        return try? WidgetLayout(json: body.layout.filled(with: body.data.movingExampleTimes(to: .now), for: .widget).json)
    }()

    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(date: .now, state: Self.example.map { .content($0, .systemSmall, isStale: false) } ?? .choose)
    }

    func snapshot(for configuration: WidgetSelection, in context: Context) async -> WidgetEntry {
        if context.isPreview && configuration.widget == nil {
            return placeholder(in: context)
        }
        return await timeline(for: configuration, in: context).entries[0]
    }

    func timeline(for configuration: WidgetSelection, in context: Context) async -> Timeline<WidgetEntry> {
        let now = Date.now
        guard let widget = configuration.widget else { return Self.once(.choose, at: now, policy: .never) }
        guard let family = WidgetLayout.Family(context.family) else {
            return Self.once(.unsupported(title: widget.title), at: now, policy: .never)
        }
        let answer: Result<WidgetAnswer, any Error>
        do {
            guard let gateway = GatewayClient.configured(timeout: 10), let credential = try KeychainItem.widget.load() else {
                return Self.once(.signedOut, at: now, policy: .after(now + Self.reconciliation))
            }
            let have = WidgetCache.revision(of: widget.id)
            answer = .success(try await gateway.widget(widget.id, family: family, have: have, widgetToken: credential.widgetToken))
        } catch {
            answer = .failure(error)
        }
        switch WidgetCache.record(answer, for: widget.id, at: now) {
        case let .current(snapshot):
            return Self.timeline(snapshot, family: family, isCurrent: true, at: now, reload: Self.reload(after: snapshot, at: now))
        case let .unreachable(snapshot?, failures):
            return Self.timeline(snapshot, family: family, isCurrent: false, at: now, reload: Self.retry(after: failures, at: now))
        case let .unreachable(nil, failures):
            return Self.once(.unreachable(title: widget.title), at: now, policy: .after(Self.retry(after: failures, at: now)))
        case .deleted:
            return Self.once(.removed(title: widget.title), at: now, policy: .never)
        case .signedOut:
            return Self.once(.signedOut, at: now, policy: .after(now + Self.reconciliation))
        }
    }

    private static func timeline(_ snapshot: WidgetSnapshot, family: WidgetLayout.Family, isCurrent: Bool, at now: Date, reload: Date) -> Timeline<WidgetEntry> {
        guard case let .layout(json) = snapshot.content, let layout = try? WidgetLayout(json: json.json) else {
            return once(.updateApp(title: snapshot.title), at: now, policy: .never)
        }
        guard layout.presentations[family] != nil else { return once(.unsupported(title: snapshot.title), at: now, policy: .never) }
        let isStale = !isCurrent || snapshot.staleAt.map { $0 <= now } == true
        var entries = [WidgetEntry(date: now, state: .content(layout, family, isStale: isStale))]
        if !isStale, let staleAt = snapshot.staleAt {
            entries.append(WidgetEntry(date: staleAt, state: .content(layout, family, isStale: true)))
        }
        return Timeline(entries: entries, policy: .after(reload))
    }

    private static func reload(after snapshot: WidgetSnapshot, at now: Date) -> Date {
        let reconciled = now + reconciliation
        guard let staleAt = snapshot.staleAt, staleAt > now else { return reconciled }
        return min(staleAt, reconciled)
    }

    private static func retry(after failures: Int, at now: Date) -> Date {
        now + (failures <= 1 ? 15 * 60 : 3600)
    }

    private static func once(_ state: WidgetEntry.State, at now: Date, policy: TimelineReloadPolicy) -> Timeline<WidgetEntry> {
        Timeline(entries: [WidgetEntry(date: now, state: state)], policy: policy)
    }
}
