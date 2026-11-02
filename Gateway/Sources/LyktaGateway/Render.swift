import Foundation
import LyktaCore

enum RenderInput: Encodable, Sendable {
    enum Avatar: Sendable {
        case drawing(JSONValue)
        case image([UInt8])
    }

    case activity(title: String, layout: JSONValue, data: JSONValue)
    case widget(layout: JSONValue, data: JSONValue)
    case notification(sender: NotificationRequest.Sender, body: String, avatar: Avatar?, image: [UInt8]?)

    func encode(to encoder: any Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .activity(title, layout, data):
            try fields.encode("activity", forKey: .kind)
            try fields.encode(title, forKey: .title)
            try fields.encode(layout, forKey: .layout)
            try fields.encode(data, forKey: .data)
        case let .widget(layout, data):
            try fields.encode("widget", forKey: .kind)
            try fields.encode(layout, forKey: .layout)
            try fields.encode(data, forKey: .data)
        case let .notification(sender, body, avatar, image):
            try fields.encode("notification", forKey: .kind)
            try fields.encode(JSONValue.object(["id": .string(sender.id.rawValue), "name": .string(sender.name)]), forKey: .sender)
            try fields.encode(body, forKey: .body)
            switch avatar {
            case let .drawing(node)?: try fields.encode(JSONValue.object(["drawing": node]), forKey: .avatar)
            case let .image(bytes)?: try fields.encode(JSONValue.object(["image": .string(Data(bytes).base64EncodedString())]), forKey: .avatar)
            case nil: break
            }
            try fields.encodeIfPresent(image.map { Data($0) }, forKey: .image)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, title, layout, data, sender, body, avatar, image
    }
}

struct RenderJob: Encodable, Sendable {
    let id: UUID
    let name: Name
    let input: RenderInput
    let presentations: [String]
    let device: UUID

    private enum CodingKeys: String, CodingKey {
        case id, name, input, presentations
    }
}

struct RenderResult: Decodable, Sendable {
    enum Outcome: Sendable {
        case image([UInt8])
        case failure(String)
    }

    let outcome: Outcome
    let warnings: [String]

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        if let error = try fields.decodeIfPresent(String.self, forKey: .error) {
            outcome = .failure(error)
        } else {
            let image = try fields.decode(Data.self, forKey: .image)
            guard image.count <= RenderQueue.maximumImageBytes else {
                throw DecodingError.dataCorruptedError(forKey: .image, in: fields, debugDescription: "must be at most \(RenderQueue.maximumImageBytes) bytes")
            }
            outcome = .image(Array(image))
        }
        warnings = try fields.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case image, error, warnings
    }
}

struct RenderReply: Encodable, Sendable {
    let id: UUID
    let warnings: [String]
}

actor RenderQueue {
    static let wait = 25
    static let maximumImageBytes = 4 << 20
    private static let workerTimeout = Duration.seconds(wait + 10)
    private static let maximumPending = 16
    private static let maximumPendingPerDevice = 2
    private static let imageLifetime = Duration.seconds(600)
    private static let maximumImages = 16

    private struct Image {
        let device: UUID
        let bytes: [UInt8]
        let expires: ContinuousClock.Instant
    }

    private let workerTokenHash: String?
    private var pending: [RenderJob] = []
    private var claimed: [UUID: RenderJob] = [:]
    private var finished: [UUID: Result<RenderReply, APIError>] = [:]
    private var images: [UUID: Image] = [:]
    private var lastPoll: ContinuousClock.Instant?

    init(workerTokenHash: String?) {
        self.workerTokenHash = workerTokenHash
    }

    nonisolated func isWorker(_ token: String) -> Bool {
        workerTokenHash == Store.hash(token)
    }

    func submit(device: UUID, name: Name, input: RenderInput, presentations: [String]) throws(APIError) -> UUID {
        removeExpiredImages()
        guard let lastPoll, ContinuousClock.now - lastPoll < Self.workerTimeout else {
            throw APIError(.renderUnavailable, "No renderer is connected to this gateway. Send the PUT and look at the phone instead.")
        }
        guard pending.count + claimed.count < Self.maximumPending,
              pending.count(where: { $0.device == device }) + claimed.values.count(where: { $0.device == device }) < Self.maximumPendingPerDevice else {
            var error = APIError(.renderUnavailable, "The renderer is busy. Render again in a few seconds, one at a time.")
            error.retryAfter = 5
            throw error
        }
        let job = RenderJob(id: UUID(), name: name, input: input, presentations: presentations, device: device)
        pending.append(job)
        return job.id
    }

    func outcome(of id: UUID) -> Result<RenderReply, APIError>? {
        finished.removeValue(forKey: id)
    }

    func abandon(_ id: UUID) {
        pending.removeAll { $0.id == id }
        claimed[id] = nil
        finished[id] = nil
    }

    func claim() -> RenderJob? {
        lastPoll = .now
        removeExpiredImages()
        guard !pending.isEmpty else { return nil }
        let job = pending.removeFirst()
        claimed[job.id] = job
        return job
    }

    func complete(_ id: UUID, with result: RenderResult) throws(APIError) {
        guard let job = claimed.removeValue(forKey: id) else {
            throw APIError(.notFound, "No claimed render has the id \(id); its agent stopped waiting.")
        }
        switch result.outcome {
        case let .image(bytes):
            removeExpiredImages()
            while images.count >= Self.maximumImages, let oldest = images.min(by: { $0.value.expires < $1.value.expires }) {
                images[oldest.key] = nil
            }
            images[id] = Image(device: job.device, bytes: bytes, expires: .now + Self.imageLifetime)
            finished[id] = .success(RenderReply(id: id, warnings: result.warnings))
        case let .failure(message):
            finished[id] = .failure(APIError(.renderFailed, "The renderer could not draw it: \(message)"))
        }
    }

    func image(_ id: UUID, device: UUID) throws(APIError) -> [UInt8] {
        removeExpiredImages()
        guard let image = images[id], image.device == device else {
            throw APIError(.notFound, "No render has the id \(id); renders are kept for ten minutes.")
        }
        return image.bytes
    }

    private func removeExpiredImages() {
        let now = ContinuousClock.now
        images = images.filter { $0.value.expires > now }
    }
}
