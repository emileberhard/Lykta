#if DEBUG
import ImageIO
import LyktaCore
import SwiftUI
import UniformTypeIdentifiers

enum Capture {
    static let directory = ProcessInfo.processInfo.environment["LYKTA_CAPTURE"].map { URL(filePath: $0) }
}

struct CaptureView: View {
    private static let scale: CGFloat = 6
    private static let width: CGFloat = 370
    private static let locale = Locale(identifier: "en_US")
    private static let timeZone: TimeZone = {
        let offset = (9 * 3600 + 41 * 60 - Int(Date.now.timeIntervalSince1970) % 86400) / 60 * 60
        return TimeZone(secondsFromGMT: (offset + 86400 + 43200) % 86400 - 43200)!
    }()

    let directory: URL

    var body: some View {
        Color.black
            .task {
                do {
                    try await capture()
                    exit(0)
                } catch {
                    print("capture failed: \(error)")
                    exit(1)
                }
            }
    }

    private func capture() async throws {
        let cards = directory.appending(path: "cards")
        for card in try await Example.load(from: cards, at: .now) {
            try render(LockScreenCard(state: card.preview, activity: nil, isStale: false)
                .background(card.preview.layout?.background?.value ?? .clear)
                .frame(width: Self.width), named: "\(card.id).lock")
        }
        for widget in try await WidgetExample.load(from: cards.appending(path: "widgets"), at: .now) {
            for family in widget.families {
                try render(WidgetPreview(layout: widget.layout, family: family), named: "\(widget.id).\(family.rawValue)")
            }
        }
        for notification in try await NotificationExample.load(from: cards.appending(path: "notifications")) {
            try render(NotificationAvatar(avatar: notification.avatar), named: "\(notification.id).avatar")
        }
        try render(Lights(separation: 0).frame(height: 400), named: "lights")
    }

    private func render(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.locale, Self.locale).environment(\.timeZone, Self.timeZone))
        renderer.scale = Self.scale
        guard let image = renderer.cgImage else { throw CaptureError("could not render \(name)") }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError("could not create a PNG encoder for \(name)")
        }
        let dpi = 72 * Self.scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError("could not encode the \(image.width) × \(image.height) render of \(name) as PNG")
        }
        try (png as Data).write(to: directory.appending(path: "\(name).png"), options: .atomic)
    }
}

private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
