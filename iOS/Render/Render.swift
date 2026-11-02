import LyktaCore
import SwiftUI
import UIKit

struct RenderHost: UIViewControllerRepresentable {
    let output: FileHandle

    func makeUIViewController(context: Context) -> RenderController {
        RenderController(output: output)
    }

    func updateUIViewController(_ controller: RenderController, context: Context) {}
}

final class RenderController: UIViewController {
    private static let width: CGFloat = 374
    private static let scale: CGFloat = 3
    private static let canvas = CGSize(width: 1024, height: 1024)
    private static let batch = 32

    private let output: FileHandle
    private var serving: Task<Void, Never>?

    init(output: FileHandle) {
        self.output = output
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("RenderController is created in code")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard serving == nil else { return }
        Self.hideWindows()
        serving = Task { await serve() }
    }

    private func serve() async {
        do {
            try send(Ready())
            for try await line in FileHandle.standardInput.bytes.lines {
                try send(try await render(JSONDecoder().decode(Job.self, from: Data(line.utf8))))
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func hideWindows() {
        let application = (NSClassFromString("NSApplication") as? NSObject.Type)?.value(forKey: "sharedApplication") as? NSObject
        for window in application?.value(forKey: "windows") as? [NSObject] ?? [] {
            window.perform(NSSelectorFromString("orderOut:"), with: nil)
        }
    }

    private func send(_ message: some Encodable) throws {
        try output.write(contentsOf: JSONEncoder().encode(message) + Data("\n".utf8))
    }

    private func render(_ job: Job) async throws -> Result {
        var result = Result(id: job.id)
        let shots = job.inputs.flatMap { shots(of: $0, as: job.presentations, in: job.appearance.style, result: &result) }
        for start in stride(from: 0, to: shots.count, by: Self.batch) {
            let batch = shots[start..<min(start + Self.batch, shots.count)]
            let images = snapshot(batch)
            let encoded = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (index, image) in images.enumerated() {
                    if let image = image?.image {
                        group.addTask { (index, try await Self.png(image)) }
                    }
                }
                var encoded: [Int: Data] = [:]
                for try await (index, png) in group {
                    encoded[index] = png
                }
                return encoded
            }
            for (index, shot) in batch.enumerated() {
                guard let snapshot = images[index], let png = encoded[index] else {
                    result.blank.append(Result.Blank(input: shot.input, presentation: shot.presentation))
                    continue
                }
                result.renders.append(Result.Rendered(input: shot.input, presentation: shot.presentation, width: snapshot.image.size.width,
                                                      height: snapshot.image.size.height, idealHeight: shot.idealHeight,
                                                      complete: snapshot.complete, png: png))
            }
        }
        return result
    }

    private func shots(of input: Job.Input, as presentations: [Presentation], in style: UIUserInterfaceStyle, result: inout Result) -> [Shot] {
        let data = input.data.movingExampleTimes(to: .now)
        switch input.kind {
        case .activity:
            let state: LyktaActivity.ContentState
            do {
                state = try LyktaActivity.ContentState(title: input.title, layout: input.layout.filled(with: data, for: .activity).json)
            } catch {
                result.layoutErrors.append(Result.Failure(input: input.name, error: "\(error)"))
                return []
            }
            let layout = state.layout
            let keyline = layout?.keyline?.value
            return presentations.compactMap { presentation in
                switch presentation {
                case .lock:
                    let ideal = Self.measure(LockScreenView(state: state, activity: nil, isStale: false)
                        .dynamicTypeSize(LockScreenCard.textSizes), by: .idealSize, in: style)
                    return Shot(input: input.name, presentation: presentation, idealHeight: ideal,
                                host: Self.host(LockCanvas(state: state).frame(width: Self.width), in: style))
                case .expanded:
                    let ideal = Self.measure(ExpandedRegions(regions: layout?.expanded).dynamicTypeSize(LockScreenCard.textSizes),
                                             by: .proposedWidth, in: style)
                    return Shot(input: input.name, presentation: presentation, idealHeight: ideal,
                                host: Self.host(ExpandedIsland(regions: layout?.expanded, keyline: keyline).frame(width: Self.width), in: style))
                case .compact:
                    return Shot(input: input.name, presentation: presentation, idealHeight: nil,
                                host: Self.host(CompactIsland(leading: layout?.compactLeading, trailing: layout?.compactTrailing, keyline: keyline)
                                    .fixedSize(), in: style))
                case .minimal:
                    return Shot(input: input.name, presentation: presentation, idealHeight: nil,
                                host: Self.host(MinimalBubble(node: layout?.minimal, keyline: keyline).fixedSize(), in: style))
                case .small, .medium, .large, .circular, .rectangular, .inline:
                    return nil
                }
            }
        case .widget:
            let layout: WidgetLayout
            do {
                layout = try WidgetLayout(json: input.layout.filled(with: data, for: .widget).json)
            } catch {
                result.layoutErrors.append(Result.Failure(input: input.name, error: "\(error)"))
                return []
            }
            return presentations.compactMap { presentation in
                guard let family = presentation.family, layout.presentations[family] != nil else { return nil }
                return Shot(input: input.name, presentation: presentation, idealHeight: nil,
                            host: Self.host(WidgetPreview(layout: layout, family: family).fixedSize(), in: style))
            }
        }
    }

    private static func host(_ content: some View, in style: UIUserInterfaceStyle) -> UIViewController {
        let host = UIHostingController(rootView: content)
        host.traitOverrides.userInterfaceStyle = style
        host.traitOverrides.preferredContentSizeCategory = .large
        host.traitOverrides.displayScale = scale
        host.traitOverrides.horizontalSizeClass = .compact
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        return host
    }

    private static func measure(_ content: some View, by measurement: CappedHeight.Measurement, in style: UIUserInterfaceStyle) -> CGFloat {
        let capped = CappedHeight(maximum: canvas.height, measurement: measurement)
        return host(capped { content }.frame(width: width), in: style).view.sizeThatFits(canvas).height
    }

    private func snapshot(_ shots: ArraySlice<Shot>) -> [(image: UIImage, complete: Bool)?] {
        defer {
            for shot in shots where shot.host.parent != nil {
                shot.host.willMove(toParent: nil)
                shot.host.view.removeFromSuperview()
                shot.host.removeFromParent()
            }
        }
        let sizes = shots.map { shot in
            let fitted = shot.host.view.sizeThatFits(Self.canvas)
            return CGSize(width: min(fitted.width, Self.canvas.width), height: min(fitted.height, Self.canvas.height))
        }
        for (shot, size) in zip(shots, sizes) where size.width > 0 && size.height > 0 {
            addChild(shot.host)
            shot.host.view.frame = CGRect(origin: .zero, size: size)
            view.addSubview(shot.host.view)
            shot.host.didMove(toParent: self)
        }
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.scale
        format.preferredRange = .standard
        var updated = false
        return zip(shots, sizes).map { shot, size in
            guard size.width > 0, size.height > 0 else { return nil }
            var complete = false
            let image = UIGraphicsImageRenderer(bounds: shot.host.view.bounds, format: format).image { _ in
                complete = shot.host.view.drawHierarchy(in: shot.host.view.bounds, afterScreenUpdates: !updated)
            }
            updated = true
            return (image, complete)
        }
    }

    @concurrent private static func png(_ image: UIImage) async throws -> Data {
        guard let png = image.pngData() else { throw RenderError("could not encode a render as PNG") }
        return png
    }
}

private struct Shot {
    let input: String
    let presentation: Presentation
    let idealHeight: CGFloat?
    let host: UIViewController
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

private struct Ready: Encodable {
    let ready = true
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

    let id: String
    let inputs: [Input]
    let presentations: [Presentation]
    let appearance: Appearance
}

private struct Result: Encodable {
    struct Rendered: Encodable {
        let input: String
        let presentation: Presentation
        let width: CGFloat
        let height: CGFloat
        let idealHeight: CGFloat?
        let complete: Bool
        let png: Data
    }

    struct Blank: Encodable {
        let input: String
        let presentation: Presentation
    }

    struct Failure: Encodable {
        let input: String
        let error: String
    }

    let id: String
    var renders: [Rendered] = []
    var blank: [Blank] = []
    var layoutErrors: [Failure] = []
}

nonisolated private struct RenderError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
