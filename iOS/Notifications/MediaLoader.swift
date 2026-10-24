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
    static let shared = MediaCache(appGroup: Bundle.main.object(forInfoDictionaryKey: "LyktaAppGroup") as? String)

    private static let maximumFiles = 64
    private static let maximumBytes = 64 << 20

    let sounds: URL?
    let avatars: URL?
    private let leases = Mutex<[String: Int]>([:])

    private init(appGroup: String?) {
        let container = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        sounds = container?.appending(path: "Library/Sounds", directoryHint: .isDirectory)
        avatars = container?.appending(path: "Library/Caches/Avatars", directoryHint: .isDirectory)
        for directory in [sounds, avatars].compactMap(\.self) {
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
        let files = [sounds, avatars].compactMap(\.self).flatMap {
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
    private let state = Mutex(State())

    init(payload: NotificationPayload, host: String, cache: MediaCache) {
        self.payload = payload
        self.host = host
        self.cache = cache
    }

    func load(within timeout: TimeInterval) -> Media {
        let avatar = payload.avatar.flatMap { id in cache.avatars?.appending(path: "\(id.rawValue).png") }
        let sound = payload.sound.flatMap { id in cache.sounds?.appending(path: "\(id.rawValue).wav") }
        let leased = [avatar, sound].compactMap(\.self)
        let cached = cache.lease(leased)
        defer { cache.release(leased) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: RefusingRedirects(), delegateQueue: nil)
        let pending = DispatchGroup()
        if let id = payload.avatar, let avatar {
            if cached.contains(avatar), let data = try? Data(contentsOf: avatar) {
                publish { $0.avatar = data }
            } else {
                fetch(id, in: session, group: pending) { location, type in
                    guard type.hasPrefix("image/"), let data = Self.thumbnail(of: location) else { return }
                    try? data.write(to: avatar, options: .atomic)
                    self.publish { $0.avatar = data }
                }
            }
        }
        if let id = payload.sound, let sound {
            if cached.contains(sound) {
                publish { $0.sound = sound.lastPathComponent }
            } else {
                fetch(id, in: session, group: pending) { location, type in
                    guard type == "audio/wav", rename(location.path, sound.path) == 0 else { return }
                    self.publish { $0.sound = sound.lastPathComponent }
                }
            }
        }
        if let id = payload.image {
            fetch(id, in: session, group: pending) { location, type in
                guard let format = ["image/png": "png", "image/jpeg": "jpg"][type] else { return }
                let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format)")
                guard rename(location.path, file.path) == 0 else { return }
                if !self.publish({ $0.image = file }) {
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
    private func publish(_ change: (inout Media) -> Void) -> Bool {
        state.withLock { state in
            guard !state.isClosed else { return false }
            change(&state.media)
            return true
        }
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
