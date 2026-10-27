import Foundation
import LyktaCore

nonisolated enum WidgetCache {
    enum Outcome: Sendable {
        case current(WidgetSnapshot)
        case unreachable(WidgetSnapshot?, failures: Int)
        case deleted
        case signedOut
    }

    private struct Entry: Codable {
        var title: String
        var snapshot: WidgetSnapshot?
        var isDeleted = false
        var failures = 0
        var usedAt: Date
    }

    private static let maximumEntries = 64

    static func revision(of id: UUID) -> Int? {
        update { entries in
            guard let entry = entries[id.uuidString], !entry.isDeleted else { return nil }
            return entry.snapshot?.revision
        }
    }

    static func record(_ answer: Result<WidgetAnswer, any Error>, for id: UUID, at now: Date) -> Outcome {
        update { entries in
            var entry = entries[id.uuidString] ?? Entry(title: "", usedAt: now)
            entry.usedAt = now
            defer { entries[id.uuidString] = entry }
            guard !entry.isDeleted else { return .deleted }
            switch answer {
            case let .success(.snapshot(snapshot)):
                entry.failures = 0
                guard let cached = entry.snapshot, cached.revision > snapshot.revision else {
                    entry.snapshot = snapshot
                    entry.title = snapshot.title
                    return .current(snapshot)
                }
                return .current(cached)
            case .success(.unchanged):
                guard let cached = entry.snapshot else {
                    entry.failures += 1
                    return .unreachable(nil, failures: entry.failures)
                }
                entry.failures = 0
                return .current(cached)
            case .success(.deleted):
                entry.isDeleted = true
                entry.snapshot = nil
                return .deleted
            case .success(.signedOut):
                return .signedOut
            case .failure:
                entry.failures += 1
                return .unreachable(entry.snapshot, failures: entry.failures)
            }
        }
    }

    static func remember(_ widgets: [WidgetSummary], at now: Date) {
        update { entries in
            for widget in widgets where entries[widget.id.uuidString]?.isDeleted != true {
                var entry = entries[widget.id.uuidString] ?? Entry(title: widget.title, usedAt: now)
                entry.title = widget.title
                entries[widget.id.uuidString] = entry
            }
        }
    }

    static func titles() -> [(id: UUID, title: String)] {
        update { entries in
            entries.filter { !$0.value.isDeleted && !$0.value.title.isEmpty }
                .sorted { $0.value.usedAt > $1.value.usedAt }
                .compactMap { key, entry in UUID(uuidString: key).map { ($0, entry.title) } }
        }
    }

    private static func update<Result>(_ body: (inout [String: Entry]) -> Result) -> Result {
        let directory = AppGroup.container.appending(path: "Library/Application Support/Widgets", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appending(path: "cache.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { if lock >= 0 { close(lock) } }
        if lock >= 0 { flock(lock, LOCK_EX) }
        let file = directory.appending(path: "cache.json")
        var entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
        let result = body(&entries)
        if entries.count > maximumEntries {
            for (key, _) in entries.sorted(by: { $0.value.usedAt > $1.value.usedAt }).dropFirst(maximumEntries) {
                entries[key] = nil
            }
        }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: file, options: .atomic)
        }
        return result
    }
}
