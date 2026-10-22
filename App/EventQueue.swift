import Foundation
import LyktaCore

final class EventQueue {
    private static let maximumBytes = 4 << 20
    private static let maximumBatchBytes = 768 << 10

    private(set) var events: [Event] = []
    private let file = URL.applicationSupportDirectory.appending(path: "events.json")

    init() {
        guard FileManager.default.fileExists(atPath: file.path()) else { return }
        do {
            events = try JSONDecoder().decode([Event].self, from: Data(contentsOf: file))
        } catch {
            append(Event(id: UUID(), at: .now, name: "telemetry.unreadable", activity: nil, detail: .object(["error": .string("\(error)")])))
        }
    }

    func append(_ event: Event) {
        events.append(event)
        persist()
    }

    func batch() -> [Event] {
        var bytes = 0
        var batch: [Event] = []
        for event in events.prefix(EventBatch.maximumEvents) {
            bytes += event.detail.json.count + 256
            guard batch.isEmpty || bytes <= Self.maximumBatchBytes else { break }
            batch.append(event)
        }
        return batch
    }

    func clear() {
        events = []
        persist()
    }

    func remove(_ sent: [Event]) {
        let ids = Set(sent.map(\.id))
        events.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        do {
            var data = try JSONEncoder().encode(events)
            while data.count > Self.maximumBytes {
                let dropped = max(1, events.count / 10)
                events.removeFirst(dropped)
                events.append(Event(id: UUID(), at: .now, name: "telemetry.dropped", activity: nil,
                                    detail: .object(["count": .number(Double(dropped))])))
                data = try JSONEncoder().encode(events)
            }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            events.append(Event(id: UUID(), at: .now, name: "telemetry.unsaved", activity: nil, detail: .object(["error": .string("\(error)")])))
        }
    }
}
