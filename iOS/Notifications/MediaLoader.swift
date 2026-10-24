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

nonisolated final class MediaLoader: Sendable {
    private static let maximumFiles = 64
    private static let maximumBytes = 64 << 20
    private static let avatarPixels = 256

    private let payload: NotificationPayload
    private let host: String
    private let sounds: URL?
    private let avatars: URL?
    private let loaded = Mutex(Media())

    init(payload: NotificationPayload, host: String, appGroup: String?) {
        self.payload = payload
        self.host = host
        let container = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
        sounds = container?.appending(path: "Library/Sounds", directoryHint: .isDirectory)
        avatars = container?.appending(path: "Library/Caches/Avatars", directoryHint: .isDirectory)
        for directory in [sounds, avatars].compactMap(\.self) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func load(within timeout: TimeInterval) -> Media {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: RefusingRedirects(), delegateQueue: nil)
        let pending = DispatchGroup()
        var used: Set<String> = []
        if let id = payload.avatar, let avatars {
            let file = avatars.appending(path: "\(id.rawValue).png")
            used.insert(file.lastPathComponent)
            if Self.touch(file), let data = try? Data(contentsOf: file) {
                loaded.withLock { $0.avatar = data }
            } else {
                fetch(id, in: session, group: pending) { location, type in
                    guard type.hasPrefix("image/"), let data = Self.thumbnail(of: location) else { return }
                    try? data.write(to: file, options: .atomic)
                    self.loaded.withLock { $0.avatar = data }
                }
            }
        }
        if let id = payload.sound, let sounds {
            let file = sounds.appending(path: "\(id.rawValue).wav")
            used.insert(file.lastPathComponent)
            if Self.touch(file) {
                loaded.withLock { $0.sound = file.lastPathComponent }
            } else {
                fetch(id, in: session, group: pending) { location, type in
                    guard type == "audio/wav", rename(location.path, file.path) == 0 else { return }
                    self.loaded.withLock { $0.sound = file.lastPathComponent }
                }
            }
        }
        if let id = payload.image {
            fetch(id, in: session, group: pending) { location, type in
                guard let format = ["image/png": "png", "image/jpeg": "jpg"][type] else { return }
                let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format)")
                guard rename(location.path, file.path) == 0 else { return }
                self.loaded.withLock { $0.image = file }
            }
        }
        _ = pending.wait(timeout: .now() + timeout + 1)
        session.invalidateAndCancel()
        trim(keeping: used)
        return loaded.withLock { $0 }
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

    private func trim(keeping used: Set<String>) {
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
        for entry in entries where !used.contains(entry.file.lastPathComponent) {
            guard count > Self.maximumFiles || bytes > Self.maximumBytes else { break }
            guard (try? FileManager.default.removeItem(at: entry.file)) != nil else { continue }
            count -= 1
            bytes -= entry.size
        }
    }

    private static func touch(_ file: URL) -> Bool {
        (try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)) != nil
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
