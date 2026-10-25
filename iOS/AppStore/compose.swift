import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas = CGSize(width: 1206, height: 2622)
let captures = URL(filePath: CommandLine.arguments[1])
let examples = URL(filePath: CommandLine.arguments[2])
let output = URL(filePath: CommandLine.arguments[3])

func image(_ url: URL) -> NSImage {
    guard let image = NSImage(contentsOf: url) else { fatalError("missing \(url.path)") }
    return image
}

func capture(_ name: String) -> NSImage {
    image(captures.appending(path: "\(name).png"))
}

enum Light {
    case pink, amber, blue

    var color: Color {
        switch self {
        case .pink: Color(red: 1, green: 0.310, blue: 0.545)
        case .amber: Color(red: 1, green: 0.690, blue: 0.125)
        case .blue: Color(red: 0.184, green: 0.482, blue: 1)
        }
    }

    func shape(size: CGFloat) -> AnyShape {
        switch self {
        case .pink: AnyShape(Circle())
        case .amber: AnyShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
        case .blue: AnyShape(Triangle())
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct Glow: View {
    let light: Light
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    var opacity = 0.8

    var body: some View {
        light.shape(size: size)
            .fill(light.color)
            .frame(width: size, height: size)
            .blur(radius: size * 0.22)
            .opacity(opacity)
            .position(x: x, y: y)
            .blendMode(.screen)
    }
}

struct Night: View {
    let glows: [Glow]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.024, blue: 0.055), Color(red: 0.045, green: 0.05, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom)
            ForEach(glows.indices, id: \.self) { glows[$0] }
        }
        .compositingGroup()
    }
}

struct Grain: View {
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x4C796B7461
            func next() -> UInt64 {
                seed &+= 0x9E3779B97F4A7C15
                var z = seed
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return z ^ (z >> 31)
            }
            for _ in 0..<Int(size.width * size.height / 40) {
                let value = next()
                let point = CGPoint(x: Double(value % UInt64(size.width)), y: Double((value >> 20) % UInt64(size.height)))
                let shade: Color = value >> 63 == 0 ? .white.opacity(0.045) : .black.opacity(0.07)
                context.fill(Path(CGRect(origin: point, size: CGSize(width: 2, height: 2))), with: .color(shade))
            }
        }
    }
}

struct Caption: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            Text(title)
                .font(.system(size: 118, weight: .bold).leading(.tight))
                .tracking(-2.5)
            Text(subtitle)
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(.white.opacity(0.62))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 96)
        .padding(.top, 180)
    }
}

struct Slide<Art: View>: View {
    let title: String
    let subtitle: String
    let glows: [Glow]
    @ViewBuilder let art: Art

    var body: some View {
        ZStack(alignment: .topLeading) {
            Night(glows: glows)
            art
            Caption(title: title, subtitle: subtitle)
            Grain().blendMode(.overlay)
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

extension View {
    func lifted() -> some View {
        shadow(color: .black.opacity(0.65), radius: 60, y: 34)
    }

    func scaled(_ scale: CGFloat, from size: CGSize) -> some View {
        frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
    }
}

enum Screen {
    static let size = CGSize(width: 402, height: 874)
    static let cornerRadius: CGFloat = 62
}

struct Phone<Content: View>: View {
    static var size: CGSize { CGSize(width: Screen.size.width + 15, height: Screen.size.height + 15) }

    let scale: CGFloat
    var showsCamera = true
    @ViewBuilder let content: Content

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: Screen.cornerRadius + 7.5, style: .continuous)
        ZStack {
            outer.fill(LinearGradient(colors: [Color(white: 0.58), Color(white: 0.2), Color(white: 0.1), Color(white: 0.42)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            outer.strokeBorder(AngularGradient(colors: [Light.pink.color, Light.amber.color, Light.blue.color, Light.pink.color],
                                               center: .center), lineWidth: 1.2)
                .opacity(0.7)
            RoundedRectangle(cornerRadius: Screen.cornerRadius + 5, style: .continuous).fill(.black).padding(2.5)
            content
                .frame(width: Screen.size.width, height: Screen.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Screen.cornerRadius, style: .continuous))
                .overlay(alignment: .top) {
                    if showsCamera {
                        Capsule().fill(.black).frame(width: 126, height: 37).padding(.top, 11)
                    }
                }
        }
        .scaled(scale, from: Self.size)
    }
}

struct Wallpaper: View {
    var body: some View {
        Night(glows: [
            Glow(light: .pink, x: 330, y: 150, size: 420, opacity: 0.55),
            Glow(light: .blue, x: 40, y: 600, size: 520, opacity: 0.5),
            Glow(light: .amber, x: 390, y: 860, size: 380, opacity: 0.4),
        ])
    }
}

struct StatusBar: View {
    var showsTime = true
    var symbols = ["cellularbars", "wifi", "battery.100percent"]

    var body: some View {
        HStack {
            Text("9:41")
                .font(.system(size: 17, weight: .semibold))
                .opacity(showsTime ? 1 : 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(symbols, id: \.self) { Image(systemName: $0) }
            }
            .font(.system(size: 15, weight: .semibold))
        }
        .padding(.leading, 50)
        .padding(.trailing, 32)
        .frame(height: 59)
        .foregroundStyle(.white)
    }
}

struct LockScreen<Stack: View>: View {
    @ViewBuilder let stack: Stack

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            VStack(spacing: 0) {
                StatusBar(showsTime: false)
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.top, 10)
                Text("Sunday, October 25")
                    .font(.system(size: 20, weight: .semibold))
                    .opacity(0.85)
                    .padding(.top, 12)
                Text("9:41")
                    .font(.system(size: 108, weight: .bold))
                    .tracking(-1)
                    .opacity(0.94)
                    .padding(.top, -8)
                VStack(spacing: 10) { stack }
                    .padding(.top, 22)
                Spacer(minLength: 0)
                QuickActions()
            }
            .foregroundStyle(.white)
        }
    }
}

struct QuickActions: View {
    var body: some View {
        VStack(spacing: 22) {
            HStack {
                button("flashlight.off.fill")
                Spacer()
                button("camera.fill")
            }
            .padding(.horizontal, 46)
            Capsule().fill(.white).frame(width: 140, height: 5)
        }
        .padding(.bottom, 9)
    }

    private func button(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .frame(width: 50, height: 50)
            .background(.white.opacity(0.14), in: Circle())
    }
}

struct Platter: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(red: 0.07, green: 0.07, blue: 0.1).opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

struct Card: View {
    let name: String

    var body: some View {
        let image = capture("\(name).lock")
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: image.size.width, height: image.size.height)
            .modifier(Platter())
    }
}

struct AppIcon: View {
    var body: some View {
        Image(nsImage: capture("lights"))
            .resizable()
            .scaledToFit()
            .padding(2.5)
            .background(.black, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
    }
}

struct Banner: View {
    let example: String
    var time = "now"

    var body: some View {
        let request = try! JSONSerialization.jsonObject(with: Data(contentsOf: examples.appending(path: "notifications/\(example).json"))) as! [String: Any]
        let sender = request["sender"] as! [String: Any]
        HStack(spacing: 12) {
            Image(nsImage: capture("\(example).avatar"))
                .resizable()
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    AppIcon().frame(width: 18, height: 18).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender["name"] as! String).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Text(time).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }
                Text(request["body"] as! String).font(.system(size: 15)).lineLimit(3)
            }
            if let attachment = request["image"] as? String {
                Image(nsImage: image(examples.appending(path: "notifications/\(attachment)")))
                    .resizable()
                    .scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 370)
        .modifier(Platter())
    }
}

struct Island: View {
    let name: String
    let presentation: String

    var body: some View {
        let image = capture("\(name).\(presentation)")
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: image.size.width, height: image.size.height)
    }
}

struct Faded: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height)
        }
    }
}

let slides: [(String, AnyView)] = [
    ("1-agents", AnyView(Slide(title: "Watch your\nagents work", subtitle: "Live on your Lock Screen", glows: [
        Glow(light: .pink, x: 1060, y: 520, size: 1100, opacity: 0.85),
        Glow(light: .amber, x: 120, y: 1500, size: 900, opacity: 0.7),
        Glow(light: .blue, x: 700, y: 2550, size: 1300, opacity: 0.85),
    ]) {
        Phone(scale: 2.43) {
            LockScreen {
                Card(name: "agent-question")
                Card(name: "app-review")
                Card(name: "homelab")
            }
        }
        .lifted()
        .offset(x: 96, y: 720)
    })),
    ("2-notifications", AnyView(Slide(title: "Hear back the\nmoment it’s done", subtitle: "Agents message you like a person would", glows: [
        Glow(light: .amber, x: 980, y: 640, size: 1250, opacity: 0.9),
        Glow(light: .pink, x: 80, y: 2150, size: 950, opacity: 0.65),
        Glow(light: .blue, x: 1150, y: 2650, size: 900, opacity: 0.55),
    ]) {
        Phone(scale: 2.3) {
            LockScreen {
                Banner(example: "tests-passed", time: "12m ago")
                Card(name: "orion-return")
            }
        }
        .lifted()
        .offset(x: 127, y: 900)
        Banner(example: "print-finished")
            .scaleEffect(2.75, anchor: .topLeading)
            .lifted()
            .offset(x: 94, y: 730)
    })),
    ("3-dynamic-island", AnyView(Slide(title: "Progress\nat a glance", subtitle: "Right in the Dynamic Island", glows: [
        Glow(light: .blue, x: 640, y: 1250, size: 1450, opacity: 0.9),
        Glow(light: .pink, x: 60, y: 420, size: 760, opacity: 0.6),
        Glow(light: .amber, x: 1150, y: 2450, size: 950, opacity: 0.55),
    ]) {
        Island(name: "orion-return", presentation: "expanded")
            .scaleEffect(3, anchor: .topLeading)
            .lifted()
            .offset(x: 48, y: 690)
        Phone(scale: 2.75, showsCamera: false) {
            ZStack(alignment: .top) {
                Image(nsImage: capture("home")).resizable().blur(radius: 9).overlay(.black.opacity(0.3))
                StatusBar(symbols: ["wifi", "battery.100percent"])
                Island(name: "solar-eclipse", presentation: "compact").padding(.top, 11)
            }
        }
        .modifier(Faded(height: 820))
        .lifted()
        .offset(x: 30, y: 1560)
    })),
    ("4-layouts", AnyView(Slide(title: "Designed by\nyour agent", subtitle: "Any layout, without an app update", glows: [
        Glow(light: .pink, x: 640, y: 1550, size: 1500, opacity: 0.75),
        Glow(light: .amber, x: 1120, y: 820, size: 760, opacity: 0.6),
        Glow(light: .blue, x: 80, y: 2350, size: 950, opacity: 0.65),
    ]) {
        ForEach(Array(["solar-eclipse", "recipe-steps", "movie-night", "homelab", "puppy-potty"].enumerated()), id: \.offset) { index, name in
            Card(name: name)
                .scaled(2.5, from: capture("\(name).lock").size)
                .rotationEffect(.degrees(index.isMultiple(of: 2) ? -2.5 : 2))
                .lifted()
                .offset(x: index.isMultiple(of: 2) ? -40 : 320, y: 660 + CGFloat(index) * 385)
        }
    })),
    ("5-setup", AnyView(Slide(title: "Set up in\none paste", subtitle: "Copy the setup and hand it to your agent", glows: [
        Glow(light: .blue, x: 1080, y: 1300, size: 1100, opacity: 0.8),
        Glow(light: .pink, x: 120, y: 1000, size: 950, opacity: 0.7),
        Glow(light: .amber, x: 600, y: 2600, size: 1100, opacity: 0.6),
    ]) {
        Phone(scale: 2.15) {
            ZStack(alignment: .top) {
                Image(nsImage: capture("home")).resizable().interpolation(.high)
                StatusBar()
            }
        }
        .lifted()
        .offset(x: 155, y: 640)
    })),
]

MainActor.assumeIsolated {
    for (name, slide) in slides {
        let renderer = ImageRenderer(content: slide.environment(\.colorScheme, .dark))
        guard let rendered = renderer.cgImage,
              let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { fatalError("could not render \(name)") }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        let url = output.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("could not create \(url.path)")
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
    }
}
