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
    private static let homeActivities = ["app-review", "agent-question"]

    let directory: URL
    @State private var model: Model?

    var body: some View {
        ZStack {
            Color.black
            if let model {
                HomeView(model: model)
            }
        }
        .preferredColorScheme(.dark)
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
        try render(Lights().frame(height: 400), named: "lights")
        model = .preview(.ready, activities: Self.homeActivities.map { id in
            let example = examples.first { $0.id == id }!
            return LiveActivity(id: id, attributes: LyktaActivity(id: UUID(), name: id), content: example.preview, state: .active)
        })
        try await Task.sleep(for: .seconds(1))
        try snapshot(await keyWindow(), named: "home")
    }

    private func render(_ view: some View, named name: String) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
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
        let url = directory.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError("could not create \(url.path)")
        }
        let dpi = 72 * scale
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError("could not write \(url.path)") }
    }
}

private struct CaptureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
