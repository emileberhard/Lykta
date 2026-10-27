import CryptoKit
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

    private struct Contents: Codable {
        var credential: String
        var entries: [String: Entry] = [:]
    }

    private struct Entry: Codable {
        var title: String
        var snapshot: WidgetSnapshot?
        var isDeleted = false
        var failures = 0
        var usedAt: Date
    }

    private static let maximumEntries = 64

    static func snapshot(of id: UUID, for credential: WidgetCredential) throws -> WidgetSnapshot? {
        try read(for: credential) { entries in
            guard let entry = entries[id.uuidString], !entry.isDeleted else { return nil }
            return entry.snapshot
        }
    }

    static func record(_ answer: Result<WidgetAnswer, any Error>, for id: UUID, fetchedWith credential: WidgetCredential, at now: Date) throws -> Outcome {
        try update(for: credential) { contents in
            guard try KeychainItem.widget.load()?.widgetToken == credential.widgetToken else { return .signedOut }
            if case .success(.signedOut) = answer {
                contents.entries = [:]
                return .signedOut
            }
            var entry = contents.entries[id.uuidString] ?? Entry(title: "", usedAt: now)
            entry.usedAt = now
            defer { contents.entries[id.uuidString] = entry }
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
        try update(for: credential) { contents in
            guard try KeychainItem.widget.load()?.widgetToken == credential.widgetToken else { return }
            for widget in widgets where contents.entries[widget.id.uuidString]?.isDeleted != true {
                var entry = contents.entries[widget.id.uuidString] ?? Entry(title: widget.title, usedAt: now)
                entry.title = widget.title
                contents.entries[widget.id.uuidString] = entry
            }
        }
    }

    static func titles(for credential: WidgetCredential) throws -> [(id: UUID, title: String)] {
        try read(for: credential) { entries in
            entries.filter { !$0.value.isDeleted && !$0.value.title.isEmpty }
                .sorted { $0.value.usedAt > $1.value.usedAt }
                .compactMap { key, entry in UUID(uuidString: key).map { ($0, entry.title) } }
        }
    }

    static func removeAll() throws {
        try AppGroup.lockingWidgets { directory in
            do {
                try FileManager.default.removeItem(at: file(in: directory))
            } catch CocoaError.fileNoSuchFile {}
        }
    }

    private static func read<Result>(for credential: WidgetCredential, _ body: ([String: Entry]) throws -> Result) throws -> Result {
        try AppGroup.lockingWidgets { directory in
            let contents = try contents(of: file(in: directory), for: credential)
            return try body(contents.entries)
        }
    }

    private static func update<Result>(for credential: WidgetCredential, _ body: (inout Contents) throws -> Result) throws -> Result {
        try AppGroup.lockingWidgets { directory in
            let file = file(in: directory)
            var contents = try contents(of: file, for: credential)
            let result = try body(&contents)
            if contents.entries.count > maximumEntries {
                for (key, _) in contents.entries.sorted(by: { $0.value.usedAt > $1.value.usedAt }).dropFirst(maximumEntries) {
                    contents.entries[key] = nil
                }
            }
            try? JSONEncoder().encode(contents).write(to: file, options: .atomic)
            return result
        }
    }

    private static func contents(of file: URL, for credential: WidgetCredential) throws -> Contents {
        let fresh = Contents(credential: fingerprint(credential))
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return fresh
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: data), contents.credential == fresh.credential else { return fresh }
        return contents
    }

    private static func fingerprint(_ credential: WidgetCredential) -> String {
        SHA256.hash(data: Data(credential.widgetToken.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func file(in directory: URL) -> URL {
        directory.appending(path: "cache.json")
    }
}
