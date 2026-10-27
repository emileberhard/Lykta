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
        case notLoaded(title: String)
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
        guard context.isPreview else { return await timeline(for: configuration, in: context).entries[0] }
        guard let widget = configuration.widget else { return placeholder(in: context) }
        let now = Date.now
        guard let family = WidgetLayout.Family(context.family), let snapshot = try? WidgetCache.snapshot(of: widget.id) else {
            return WidgetEntry(date: now, state: .notLoaded(title: widget.title))
        }
        return Self.timeline(snapshot, family: family, isCurrent: true, at: now, reload: now).entries[0]
    }

    func timeline(for configuration: WidgetSelection, in context: Context) async -> Timeline<WidgetEntry> {
        let now = Date.now
        guard let widget = configuration.widget else { return Self.once(.choose, at: now, policy: .never) }
        guard let family = WidgetLayout.Family(context.family) else {
            return Self.once(.unsupported(title: widget.title), at: now, policy: .never)
        }
        let outcome: WidgetCache.Outcome
        do {
            guard let gateway = GatewayClient.configured(timeout: 10), let credential = try KeychainItem.widget.load() else {
                return Self.once(.signedOut, at: now, policy: .after(now + Self.reconciliation))
            }
            outcome = await Self.fetch(widget.id, family: family, from: gateway, with: credential, at: now)
        } catch {
            outcome = .unreachable(try? WidgetCache.snapshot(of: widget.id), failures: 1)
        }
        switch outcome {
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
            return once(.updateApp(title: snapshot.title), at: now, policy: .after(now + reconciliation))
        }
        guard layout.presentations[family] != nil else {
            return once(.unsupported(title: snapshot.title), at: now, policy: .after(now + reconciliation))
        }
        let isStale = !isCurrent || snapshot.staleAt.map { $0 <= now } == true
        var entries = [WidgetEntry(date: now, state: .content(layout, family, isStale: isStale))]
        if !isStale, let staleAt = snapshot.staleAt {
            entries.append(WidgetEntry(date: staleAt, state: .content(layout, family, isStale: true)))
        }
        return Timeline(entries: entries, policy: .after(reload))
    }

    private static func fetch(_ id: UUID, family: WidgetLayout.Family, from gateway: GatewayClient, with credential: WidgetCredential,
                              at now: Date) async -> WidgetCache.Outcome {
        let have = (try? WidgetCache.snapshot(of: id)).flatMap(drawableRevision)
        let answer: Result<WidgetAnswer, any Error>
        do {
            answer = .success(try await gateway.widget(id, family: family, have: have, widgetToken: credential.widgetToken))
        } catch {
            answer = .failure(error)
        }
        do {
            return try WidgetCache.record(answer, for: id, fetchedWith: credential, at: now)
        } catch {
            guard (try? KeychainItem.widget.load())?.widgetToken == credential.widgetToken else { return .signedOut }
            return WidgetCache.Outcome(answer)
        }
    }

    private static func drawableRevision(_ snapshot: WidgetSnapshot) -> Int? {
        guard case let .layout(json) = snapshot.content, (try? WidgetLayout(json: json.json)) != nil else { return nil }
        return snapshot.revision
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
