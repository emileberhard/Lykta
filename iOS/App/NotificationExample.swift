import Foundation
import LyktaCore

nonisolated struct NotificationExample: Identifiable, Sendable {
    struct Route: Hashable {
        let id: String
    }

    enum Avatar: Sendable {
        case picture(Data), drawing(Node)
    }

    let id: String
    let sender: String
    let body: String
    let avatar: Avatar
    let image: Data?
    let media: [String: Data]
    private let fields: JSONValue

    var route: Route { Route(id: id) }

    @concurrent static func bundled() async -> [NotificationExample] {
        guard let folder = Bundle.main.url(forResource: "examples", withExtension: nil)?.appending(path: "notifications"),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            preconditionFailure("The app bundles the skill's examples folder")
        }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
            do {
                return try NotificationExample(file: file)
            } catch {
                preconditionFailure("examples/notifications/\(file.lastPathComponent): \(error)")
            }
        }
    }

    private init(file: URL) throws {
        let fields = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        guard case let .string(senderID) = try fields.value(at: "sender.id"), case let .string(sender) = try fields.value(at: "sender.name"),
              case let .string(body) = try fields.value(at: "body") else {
            throw LayoutError("expected a PUT body with a sender and a body")
        }
        var media: [String: Data] = [:]
        for path in ["sender.avatar", "sound", "image"] {
            if case let .string(name)? = try? fields.value(at: path) {
                media[path] = try Data(contentsOf: file.deletingLastPathComponent().appending(path: name))
            }
        }
        id = file.deletingPathExtension().lastPathComponent
        self.sender = sender
        self.body = body
        if case let .object(node)? = try? fields.value(at: "sender.avatar") {
            avatar = .drawing(try JSONValue.object(node).avatarNode())
        } else { avatar = .picture(media["sender.avatar"] ?? Initials.avatar(of: sender, sender: senderID)) }
        image = media["image"]
        self.media = media
        self.fields = fields
    }

    func request(with ids: [String: MediaID]) throws -> JSONValue {
        try ids.reduce(fields) { request, id in try request.replacing(id.key, with: .string(id.value.rawValue)) }
    }
}
