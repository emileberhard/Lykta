#if DEBUG
import LyktaCore
import SwiftUI
import UIKit

enum Render {
    static let directory = ProcessInfo.processInfo.environment["LYKTA_RENDER"].map { URL(filePath: $0) }
}

struct RenderHost: UIViewControllerRepresentable {
    let directory: URL

    func makeUIViewController(context: Context) -> RenderController {
        RenderController(directory: directory)
    }

    func updateUIViewController(_ controller: RenderController, context: Context) {}
}

final class RenderController: UIViewController {
    private static let width: CGFloat = 374
    private static let poll = Duration.milliseconds(20)

    private let directory: URL
    private var serving: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("RenderController is created in code")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard serving == nil else { return }
        print("render: serving \(directory.path)")
        serving = Task { await serve() }
    }

    private func serve() async {
        while !Task.isCancelled {
            do {
                if let request = try next() {
                    try await handle(request)
                } else {
                    try await Task.sleep(for: Self.poll)
                }
            } catch is CancellationError {
                return
            } catch {
                print("render: \(error)")
                exit(1)
            }
        }
    }

    private func next() throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "request" }
            .min { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func handle(_ request: URL) async throws {
        let id = request.deletingPathExtension().lastPathComponent
        let working = directory.appending(path: "\(id).working")
        let staging = directory.appending(path: ".\(id)")
        try FileManager.default.moveItem(at: request, to: working)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: working))
        var manifest = Manifest()
        let shots = job.inputs.flatMap { shots(of: $0, as: job.presentations, in: job.appearance.style, manifest: &manifest) }
        let images = try snapshot(shots)
        for (shot, image) in zip(shots, images) {
            manifest.record(shot.file, of: shot.input, complete: image.complete)
        }
        let files = zip(shots, images).map { (image: $1.image, target: staging.appending(path: $0.file)) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask { try await Self.write(file.image, to: file.target) }
            }
            try await group.waitForAll()
        }
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: "manifest.json"))
        try FileManager.default.moveItem(at: staging, to: directory.appending(path: id))
        try FileManager.default.removeItem(at: working)
    }

    private func shots(of input: Job.Input, as presentations: [Presentation], in style: UIUserInterfaceStyle, manifest: inout Manifest) -> [Shot] {
        let data = input.data.movingExampleTimes(to: .now)
        switch input.kind {
        case .activity:
            let state: LyktaActivity.ContentState
            do {
                state = try LyktaActivity.ContentState(title: input.title, layout: input.layout.filled(with: data, for: .activity).json)
            } catch {
                manifest.layoutErrors.append(.init(input: input.name, error: "\(error)"))
                return []
            }
            let layout = state.layout
            let keyline = layout?.keyline?.value
            return presentations.compactMap { presentation in
                let host: UIViewController
                switch presentation {
                case .lock: host = Self.host(LockCanvas(state: state).frame(width: Self.width), in: style)
                case .expanded: host = Self.host(ExpandedIsland(regions: layout?.expanded, keyline: keyline).frame(width: Self.width), in: style)
                case .compact: host = Self.host(CompactIsland(leading: layout?.compactLeading, trailing: layout?.compactTrailing, keyline: keyline).fixedSize(), in: style)
                case .minimal: host = Self.host(MinimalBubble(node: layout?.minimal, keyline: keyline).fixedSize(), in: style)
                case .small, .medium, .large, .circular, .rectangular, .inline: return nil
                }
                return Shot(input: input.name, presentation: presentation, host: host)
            }
        case .widget:
            let layout: WidgetLayout
            do {
                layout = try WidgetLayout(json: input.layout.filled(with: data, for: .widget).json)
            } catch {
                manifest.layoutErrors.append(.init(input: input.name, error: "\(error)"))
                return []
            }
            return presentations.compactMap { presentation in
                guard let family = presentation.family, layout.presentations[family] != nil else { return nil }
                return Shot(input: input.name, presentation: presentation, host: Self.host(WidgetPreview(layout: layout, family: family).fixedSize(), in: style))
            }
        }
    }

    private static func host(_ content: some View, in style: UIUserInterfaceStyle) -> UIViewController {
        let host = UIHostingController(rootView: content)
        host.overrideUserInterfaceStyle = style
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host
    }

    private func snapshot(_ shots: [Shot]) throws -> [(image: UIImage, complete: Bool)] {
        defer {
            for shot in shots where shot.host.parent != nil {
                shot.host.willMove(toParent: nil)
                shot.host.view.removeFromSuperview()
                shot.host.removeFromParent()
            }
        }
        for shot in shots {
            let fitted = shot.host.view.sizeThatFits(view.bounds.size)
            let size = CGSize(width: min(fitted.width, view.bounds.width), height: min(fitted.height, view.bounds.height))
            guard size.width > 0, size.height > 0 else { throw RenderError("\(shot.file) has no size") }
            addChild(shot.host)
            shot.host.view.frame = CGRect(origin: .zero, size: size)
            view.addSubview(shot.host.view)
            shot.host.didMove(toParent: self)
        }
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.preferredRange = .standard
        return shots.enumerated().map { index, shot in
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: shot.host.view.bounds, format: format).image { _ in
                complete = shot.host.view.drawHierarchy(in: shot.host.view.bounds, afterScreenUpdates: index == 0)
            }
            return (image, complete)
        }
    }

    @concurrent private static func write(_ image: UIImage, to target: URL) async throws {
        guard let png = image.pngData() else { throw RenderError("could not encode \(target.lastPathComponent) as PNG") }
        try png.write(to: target)
    }
}

private struct Shot {
    let input: String
    let presentation: Presentation
    let host: UIViewController

    var file: String { "\(input)-\(presentation.rawValue).png" }
}

private struct LockCanvas: View {
    let state: LyktaActivity.ContentState

    var body: some View {
        LockScreenCard(state: state, activity: nil, isStale: false)
            .background(state.layout?.background?.value ?? Color(.secondarySystemBackground))
            .clipShape(.rect(cornerRadius: 24, style: .continuous))
    }
}

private enum Presentation: String, Codable {
    case lock, expanded, compact, minimal, small, medium, large, circular, rectangular, inline

    var family: WidgetLayout.Family? {
        switch self {
        case .lock, .expanded, .compact, .minimal: nil
        case .small: .systemSmall
        case .medium: .systemMedium
        case .large: .systemLarge
        case .circular: .accessoryCircular
        case .rectangular: .accessoryRectangular
        case .inline: .accessoryInline
        }
    }
}

private struct Job: Decodable {
    enum Kind: String, Decodable {
        case activity, widget
    }

    enum Appearance: String, Decodable {
        case light, dark

        var style: UIUserInterfaceStyle {
            switch self {
            case .light: .light
            case .dark: .dark
            }
        }
    }

    struct Input: Decodable {
        let name: String
        let kind: Kind
        let title: String
        let layout: JSONValue
        let data: JSONValue
    }

    let inputs: [Input]
    let presentations: [Presentation]
    let appearance: Appearance
}

private struct Manifest: Encodable {
    struct Rendered: Encodable {
        let input: String
        let file: String
    }

    struct Failure: Encodable {
        let input: String
        let error: String
    }

    var renders: [Rendered] = []
    var incomplete: [String] = []
    var layoutErrors: [Failure] = []

    mutating func record(_ file: String, of input: String, complete: Bool) {
        renders.append(Rendered(input: input, file: file))
        if !complete { incomplete.append(file) }
    }
}

nonisolated private struct RenderError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
#endif
