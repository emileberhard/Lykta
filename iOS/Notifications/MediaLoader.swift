import Foundation
import ImageIO
import LyktaCore
import Synchronization
import UIKit

nonisolated struct Media: Sendable {
    var avatar: Data?
    var sound: String?
    var image: URL?
}

nonisolated final class MediaCache: Sendable {
    static let shared = MediaCache()

    private static let maximumFiles = 64
    private static let maximumBytes = 64 << 20

    let sounds: URL
    let avatars: URL
    private let leases = Mutex<[String: Int]>([:])

    private init() {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LyktaAppGroup") as? String,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            preconditionFailure("The notification extension is not signed with its app group.")
        }
        sounds = container.appending(path: "Library/Sounds", directoryHint: .isDirectory)
        avatars = container.appending(path: "Library/Caches/Avatars", directoryHint: .isDirectory)
        for directory in [sounds, avatars] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func lease(_ files: [URL]) -> Set<URL> {
        leases.withLock { leases in
            for file in files {
                leases[file.lastPathComponent, default: 0] += 1
            }
            return Set(files.filter { (try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: $0.path)) != nil })
        }
    }

    func place(_ staged: URL, at file: URL) -> Bool {
        leases.withLock { _ in rename(staged.path, file.path) == 0 }
    }

    func write(_ data: Data, to file: URL) -> Bool {
        leases.withLock { _ in (try? data.write(to: file, options: .atomic)) != nil }
    }

    func release(_ files: [URL]) {
        leases.withLock { leases in
            for file in files {
                leases[file.lastPathComponent] = leases[file.lastPathComponent].flatMap { $0 > 1 ? $0 - 1 : nil }
            }
            trim(keeping: Set(leases.keys))
        }
    }

    private func trim(keeping leased: Set<String>) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = [sounds, avatars].flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: Array(keys))) ?? []
        }
        let entries = files.compactMap { file -> (file: URL, date: Date, size: Int)? in
            guard let values = try? file.resourceValues(forKeys: keys), let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (file, date, size)
        }.sorted { $0.date < $1.date }
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.size }
        for entry in entries where !leased.contains(entry.file.lastPathComponent) {
            guard count > Self.maximumFiles || bytes > Self.maximumBytes else { break }
            guard (try? FileManager.default.removeItem(at: entry.file)) != nil else { continue }
            count -= 1
            bytes -= entry.size
        }
    }
}

nonisolated final class MediaLoader: Sendable {
    private struct State {
        var media = Media()
        var isClosed = false
    }

    private static let avatarPixels = 256

    private let payload: NotificationPayload
    private let host: String
    private let cache: MediaCache
    private let avatar: URL?
    private let sound: URL?
    private let cached: Set<URL>
    private let state = Mutex(State())

    init(payload: NotificationPayload, host: String, cache: MediaCache) {
        self.payload = payload
        self.host = host
        self.cache = cache
        avatar = payload.avatar.map { id in cache.avatars.appending(path: "\(id.rawValue).png") }
        sound = payload.sound.map { id in cache.sounds.appending(path: "\(id.rawValue).wav") }
        cached = cache.lease([avatar, sound].compactMap(\.self))
    }

    func release() {
        cache.release([avatar, sound].compactMap(\.self))
    }

    func load(within timeout: TimeInterval) -> Media {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: RefusingRedirects(), delegateQueue: nil)
        let pending = DispatchGroup()
        if let id = payload.avatar, let avatar {
            if cached.contains(avatar), let data = try? Data(contentsOf: avatar) {
                publish { media in
                    media.avatar = data
                    return true
                }
            } else {
                fetch(id, in: session, group: pending) { location, type in
                    guard type.hasPrefix("image/"), let data = Self.thumbnail(of: location) else { return }
                    self.publish { media in
                        guard self.cache.write(data, to: avatar) else { return false }
                        media.avatar = data
                        return true
                    }
                }
            }
        }
        if let id = payload.sound, let sound {
            if cached.contains(sound) {
                publish { media in
                    media.sound = sound.lastPathComponent
                    return true
                }
            } else {
                fetch(id, in: session, group: pending) { location, type in
                    guard type == "audio/wav", let staged = Self.stage(location, as: "wav") else { return }
                    let placed = self.publish { media in
                        guard self.cache.place(staged, at: sound) else { return false }
                        media.sound = sound.lastPathComponent
                        return true
                    }
                    if !placed {
                        try? FileManager.default.removeItem(at: staged)
                    }
                }
            }
        }
        if let id = payload.image {
            fetch(id, in: session, group: pending) { location, type in
                guard let format = ["image/png": "png", "image/jpeg": "jpg"][type], let file = Self.stage(location, as: format) else { return }
                let published = self.publish { media in
                    media.image = file
                    return true
                }
                if !published {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        _ = pending.wait(timeout: .now() + timeout + 1)
        session.invalidateAndCancel()
        return state.withLock { state in
            state.isClosed = true
            return state.media
        }
    }

    @discardableResult
    private func publish(_ change: (inout Media) -> Bool) -> Bool {
        state.withLock { state in
            !state.isClosed && change(&state.media)
        }
    }

    private static func stage(_ download: URL, as format: String) -> URL? {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format)")
        return rename(download.path, file.path) == 0 ? file : nil
    }

    private func fetch(_ id: MediaID, in session: URLSession, group: DispatchGroup, place: @escaping @Sendable (URL, String) -> Void) {
        guard let url = URL(string: "https://\(host)/v1/device/notifications/\(payload.id.uuidString)/media/\(id.rawValue)") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(payload.token)", forHTTPHeaderField: "Authorization")
        group.enter()
        session.downloadTask(with: request) { location, response, _ in
            defer { group.leave() }
            guard let location, let response = response as? HTTPURLResponse, response.statusCode == 200, let type = response.mimeType else { return }
            place(location, type)
        }.resume()
    }

    private static func thumbnail(of file: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: avatarPixels, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}

nonisolated final class RefusingRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
