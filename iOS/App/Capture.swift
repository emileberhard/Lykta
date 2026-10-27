#if DEBUG
import ImageIO
import LyktaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum Capture {
    static let directory = ProcessInfo.processInfo.environment["LYKTA_CAPTURE"].map { URL(filePath: $0) }
}

struct CaptureView: View {
    private static let scale: CGFloat = 6
    private static let width: CGFloat = 370
    private static let homeActivities = ["app-review"]
    private static let locale = Locale(identifier: "en_US")
    private static let timeZone: TimeZone = {
        let offset = (9 * 3600 + 41 * 60 - Int(Date.now.timeIntervalSince1970) % 86400) / 60 * 60
        return TimeZone(secondsFromGMT: (offset + 86400 + 43200) % 86400 - 43200)!
    }()

    private enum Screen {
        case home(Model), connect(Model)
    }

    let directory: URL
    @State private var screen: Screen?

    var body: some View {
        ZStack {
            Color.black
            switch screen {
            case let .home(model): HomeView(model: model)
            case let .connect(model): Connect(model: model, next: {}, later: {})
            case nil: EmptyView()
            }
        }
        .preferredColorScheme(.dark)
        .environment(\.locale, Self.locale)
        .environment(\.timeZone, Self.timeZone)
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
        let examples = await Example.bundled(at: .now)
        for example in examples {
            let layout = example.preview.layout
            try render(LockScreenCard(state: example.preview, activity: nil, isStale: false)
                .background(layout?.background?.value ?? .clear)
                .frame(width: Self.width), named: "\(example.id).lock")
            try render(ExpandedIsland(regions: layout?.expanded, keyline: layout?.keyline?.value)
                .frame(width: Self.width), named: "\(example.id).expanded")
            try render(CompactIsland(leading: layout?.compactLeading, trailing: layout?.compactTrailing, keyline: layout?.keyline?.value),
                       named: "\(example.id).compact")
        }
        for example in await NotificationExample.bundled() {
            guard let avatar = UIImage(data: example.avatar) else { throw CaptureError("could not read the avatar of \(example.id)") }
            try render(Image(uiImage: avatar).resizable().scaledToFill().frame(width: 40, height: 40).clipShape(Circle()), named: "\(example.id).avatar")
        }
        try render(Lights(separation: 0).frame(height: 400), named: "lights")
        screen = .home(.preview(.ready, activities: try Self.homeActivities.map { id in
            guard let example = examples.first(where: { $0.id == id }) else { throw CaptureError("no bundled example is called \(id)") }
            let attributes = LyktaActivity(id: UUID(), name: id)
            let started = Date.now.addingTimeInterval(-25 * 60)
            return LiveActivity(id: id, attributes: attributes, content: example.preview, state: .active,
                                times: ActivityTimes(id: attributes.id, startedAt: started, updatedAt: .now.addingTimeInterval(-60), endsAt: started.addingTimeInterval(8 * 3600)),
                                isEnding: false)
        }))
        try await Task.sleep(for: .seconds(1))
        try snapshot(await keyWindow(), named: "home")
        screen = .connect(.preview(.ready))
        try await Task.sleep(for: .seconds(1))
        try snapshot(await keyWindow(), named: "connect")
    }

    private func render(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.locale, Self.locale).environment(\.timeZone, Self.timeZone))
        renderer.scale = Self.scale
        guard let image = renderer.cgImage else { throw CaptureError("could not render \(name)") }
        try write(image, scale: Self.scale, named: name)
    }

    private func keyWindow() async throws -> UIWindow {
        while true {
            let scene = UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
            if let window = scene?.keyWindow {
                return window
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func snapshot(_ window: UIWindow, named name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let cgImage = image.cgImage else { throw CaptureError("could not snapshot \(name)") }
        try write(cgImage, scale: format.scale, named: name)
    }

    private func write(_ image: CGImage, scale: CGFloat, named name: String) throws {
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError("could not create a PNG encoder for \(name)")
        }
        let dpi = 72 * scale
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
