import Foundation
import LyktaCore

extension MediaID {
    static func random() -> MediaID {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return MediaID(rawValue: "m_" + bytes.map { String($0 >> 4, radix: 16) + String($0 & 0xF, radix: 16) }.joined())!
    }
}

struct Medium: Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case sound, image
    }

    static let maximumBytes = 4 << 20
    static let maximumSoundMilliseconds = 30_000
    static let maximumImageSide = 4096

    let kind: Kind
    let contentType: String
    let milliseconds: Int?

    var seconds: Double? {
        milliseconds.map { Double($0) / 1000 }
    }

    static func validate(_ bytes: [UInt8]) throws(APIError) -> Medium {
        let file = Bytes(bytes)
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            guard bytes.count >= 24, file.ascii(at: 12, count: 4) == "IHDR" else { throw unreadable("PNG") }
            try image(width: file.bigEndian(at: 16, count: 4), height: file.bigEndian(at: 20, count: 4))
            return Medium(kind: .image, contentType: "image/png", milliseconds: nil)
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            let (width, height) = try jpegSize(file)
            try image(width: width, height: height)
            return Medium(kind: .image, contentType: "image/jpeg", milliseconds: nil)
        }
        if bytes.count >= 12, file.ascii(at: 0, count: 4) == "RIFF", file.ascii(at: 8, count: 4) == "WAVE" {
            return Medium(kind: .sound, contentType: "audio/wav", milliseconds: try wavMilliseconds(file))
        }
        throw APIError(.unsupportedMedia, "The file is not a WAV, PNG or JPEG. Convert sounds to WAV with linear PCM, such as "
                       + "`ffmpeg -i in.m4a -ac 1 -c:a pcm_s16le out.wav`, and images to PNG or JPEG.")
    }

    private static func image(width: Int, height: Int) throws(APIError) {
        guard width > 0, height > 0 else { throw unreadable("image") }
        guard width <= maximumImageSide, height <= maximumImageSide else {
            throw APIError(.unsupportedMedia, "The image is \(width)×\(height) pixels; use at most \(maximumImageSide) on each side.")
        }
    }

    private static func jpegSize(_ file: Bytes) throws(APIError) -> (Int, Int) {
        var offset = 2
        while offset + 4 <= file.count {
            guard file[offset] == 0xFF else { throw unreadable("JPEG") }
            let marker = file[offset + 1]
            if marker == 0xFF {
                offset += 1
                continue
            }
            if marker == 0x01 || (0xD0...0xD8).contains(marker) {
                offset += 2
                continue
            }
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard offset + 9 <= file.count else { break }
                return (file.bigEndian(at: offset + 7, count: 2), file.bigEndian(at: offset + 5, count: 2))
            }
            guard marker != 0xDA else { break }
            offset += 2 + file.bigEndian(at: offset + 2, count: 2)
        }
        throw unreadable("JPEG")
    }

    private static func wavMilliseconds(_ file: Bytes) throws(APIError) -> Int {
        var offset = 12
        var byteRate: Int?
        while offset + 8 <= file.count {
            let id = file.ascii(at: offset, count: 4)
            let size = file.littleEndian(at: offset + 4, count: 4)
            let body = offset + 8
            switch id {
            case "fmt ":
                guard size >= 16, body + size <= file.count else { throw unreadable("WAV") }
                var format = file.littleEndian(at: body, count: 2)
                if format == 0xFFFE, size >= 40 { format = file.littleEndian(at: body + 24, count: 2) }
                guard format == 1 else {
                    throw APIError(.unsupportedMedia, "The WAV uses audio format \(format) rather than linear PCM (1); convert it, such as with "
                                   + "`ffmpeg -i in.wav -c:a pcm_s16le out.wav`.")
                }
                byteRate = file.littleEndian(at: body + 8, count: 4)
            case "data":
                guard let byteRate, byteRate > 0 else { throw unreadable("WAV") }
                guard body + size <= file.count else { throw APIError(.unsupportedMedia, "The WAV's audio data is cut off; send the whole file.") }
                let milliseconds = Int((Double(size) * 1000 / Double(byteRate)).rounded())
                guard milliseconds > 0 else { throw APIError(.unsupportedMedia, "The WAV holds no audio.") }
                guard milliseconds < maximumSoundMilliseconds else {
                    throw APIError(.unsupportedMedia, String(format: "The sound is %.1f s long; use a clip shorter than 30 s.", Double(milliseconds) / 1000))
                }
                return milliseconds
            default:
                break
            }
            offset = body + size + size % 2
        }
        throw unreadable("WAV")
    }

    private static func unreadable(_ format: String) -> APIError {
        APIError(.unsupportedMedia, "The \(format) file is damaged or incomplete; export it again.")
    }
}

struct MediumStatus: Encodable, Sendable {
    let id: MediaID
    let type: Medium.Kind
    let durationSeconds: Double?
}

private struct Bytes {
    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var count: Int { bytes.count }

    subscript(offset: Int) -> UInt8 { bytes[offset] }

    func ascii(at offset: Int, count: Int) -> String {
        String(decoding: bytes[offset..<offset + count], as: UTF8.self)
    }

    func bigEndian(at offset: Int, count: Int) -> Int {
        guard offset + count <= bytes.count else { return 0 }
        return bytes[offset..<offset + count].reduce(0) { $0 << 8 | Int($1) }
    }

    func littleEndian(at offset: Int, count: Int) -> Int {
        guard offset + count <= bytes.count else { return 0 }
        return bytes[offset..<offset + count].reversed().reduce(0) { $0 << 8 | Int($1) }
    }
}
