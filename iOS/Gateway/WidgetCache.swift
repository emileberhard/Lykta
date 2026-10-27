import Foundation
import LyktaCore

nonisolated enum WidgetCache {
    enum Outcome: Sendable {
        case current(WidgetSnapshot)
        case unreachable(WidgetSnapshot?, failures: Int)
        case deleted
        case signedOut

        init(_ answer: Result<WidgetAnswer, any Error>) {
            self = switch answer {
            case let .success(.snapshot(snapshot)): .current(snapshot)
            case .success(.unchanged), .failure: .unreachable(nil, failures: 1)
            case .success(.deleted): .deleted
            case .success(.signedOut): .signedOut
            }
        }
    }

    private struct Entry: Codable {
        var title: String
        var snapshot: WidgetSnapshot?
        var isDeleted = false
        var failures = 0
        var usedAt: Date
    }

    private static let maximumEntries = 64

    static func snapshot(of id: UUID) throws -> WidgetSnapshot? {
        try read { entries in
            guard let entry = entries[id.uuidString], !entry.isDeleted else { return nil }
            return entry.snapshot
        }
    }

    static func record(_ answer: Result<WidgetAnswer, any Error>, for id: UUID, fetchedWith credential: WidgetCredential, at now: Date) throws -> Outcome {
        try update { entries in
            guard try KeychainItem.widget.load()?.widgetToken == credential.widgetToken else { return .signedOut }
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

    static func remember(_ widgets: [WidgetSummary], listedWith credential: WidgetCredential, at now: Date) throws {
        try update { entries in
            guard try KeychainItem.widget.load()?.widgetToken == credential.widgetToken else { return }
            for widget in widgets where entries[widget.id.uuidString]?.isDeleted != true {
                var entry = entries[widget.id.uuidString] ?? Entry(title: widget.title, usedAt: now)
                entry.title = widget.title
                entries[widget.id.uuidString] = entry
            }
        }
    }

    static func titles() throws -> [(id: UUID, title: String)] {
        try read { entries in
            entries.filter { !$0.value.isDeleted && !$0.value.title.isEmpty }
                .sorted { $0.value.usedAt > $1.value.usedAt }
                .compactMap { key, entry in UUID(uuidString: key).map { ($0, entry.title) } }
        }
    }

    static func removeAll() throws {
        try locked { file in
            do {
                try FileManager.default.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {}
        }
    }

    private static func read<Result>(_ body: ([String: Entry]) throws -> Result) throws -> Result {
        try locked { file in try body(entries(in: file)) }
    }

    private static func update<Result>(_ body: (inout [String: Entry]) throws -> Result) throws -> Result {
        try locked { file in
            var entries = try entries(in: file)
            let result = try body(&entries)
            if entries.count > maximumEntries {
                for (key, _) in entries.sorted(by: { $0.value.usedAt > $1.value.usedAt }).dropFirst(maximumEntries) {
                    entries[key] = nil
                }
            }
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            return result
        }
    }

    private static func entries(in file: URL) throws -> [String: Entry] {
        do {
            return try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        }
    }

    private static func locked<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let directory = AppGroup.container.appending(path: "Library/Application Support/Widgets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appending(path: "cache.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body(directory.appending(path: "cache.json"))
    }
}
