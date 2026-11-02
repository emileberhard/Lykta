import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

let canvas = CGSize(width: 1206, height: 2622)
let captures = URL(filePath: CommandLine.arguments[1])
let output = URL(filePath: CommandLine.arguments[2])

func capture(_ name: String) -> NSImage {
    let url = captures.appending(path: "\(name).png")
    guard let image = NSImage(contentsOf: url) else { fatalError("missing \(url.path)") }
    return image
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

let paper = [Color(red: 0.969, green: 0.949, blue: 0.914), Color(red: 0.929, green: 0.902, blue: 0.86)]
let ink = Color(red: 0.12, green: 0.1, blue: 0.09)

enum Key {
    static let amber = Color(red: 1, green: 0.64, blue: 0.1)
    static let pink = Color(red: 1, green: 0.25, blue: 0.52)
    static let teal = Color(red: 0.06, green: 0.74, blue: 0.66)
}

enum DarkKey {
    static let amber = Color(red: 0.82, green: 0.47, blue: 0)
    static let pink = Color(red: 0.86, green: 0.12, blue: 0.42)
    static let teal = Color(red: 0, green: 0.56, blue: 0.5)
}

struct Magnify: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(.unspecified)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified)
    }
}

struct Mark {
    let rect: CGRect
    let color: Color
    let radius: CGFloat
}

extension View {
    func magnified(_ scale: CGFloat) -> some View {
        Magnify(scale: scale) { scaleEffect(scale, anchor: .topLeading) }
    }

    func marked(_ marks: [Mark]) -> some View {
        overlay(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                ForEach(marks.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: marks[index].radius, style: .continuous)
                        .stroke(marks[index].color, lineWidth: 3)
                        .frame(width: marks[index].rect.width, height: marks[index].rect.height)
                        .offset(x: marks[index].rect.minX, y: marks[index].rect.minY)
                }
            }
        }
    }

    @ViewBuilder func ring(_ color: Color?) -> some View {
        if let color {
            overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(color, lineWidth: 2.5).padding(-4))
        } else {
            self
        }
    }

    func outlined(_ color: Color) -> some View {
        overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(color, lineWidth: 2.5).padding(-3))
    }
}

enum Screen {
    static let size = CGSize(width: 402, height: 874)
    static let cornerRadius: CGFloat = 62
}

struct Phone<Content: View>: View {
    static var size: CGSize { CGSize(width: Screen.size.width + 15, height: Screen.size.height + 15) }

    @ViewBuilder let content: Content

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: Screen.cornerRadius + 7.5, style: .continuous)
        ZStack {
            outer.fill(LinearGradient(colors: [Color(white: 0.44), Color(white: 0.17), Color(white: 0.1), Color(white: 0.32)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            outer.strokeBorder(.white.opacity(0.22), lineWidth: 0.8)
            RoundedRectangle(cornerRadius: Screen.cornerRadius + 5, style: .continuous).fill(.black).padding(2.5)
            content
                .frame(width: Screen.size.width, height: Screen.size.height)
                .clipShape(RoundedRectangle(cornerRadius: Screen.cornerRadius, style: .continuous))
                .overlay(alignment: .top) {
                    Capsule().fill(.black).frame(width: 126, height: 37).padding(.top, 11)
                }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .magnified(2.4)
        .shadow(color: Color(red: 0.35, green: 0.25, blue: 0.15).opacity(0.28), radius: 50, y: 30)
    }
}

struct Fold: Shape {
    let top: CGPoint
    let control1: CGPoint
    let control2: CGPoint
    let bottom: CGPoint

    var edge: Path {
        Path { path in
            path.move(to: top)
            path.addCurve(to: bottom, control1: control1, control2: control2)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = edge
        path.addLine(to: CGPoint(x: rect.maxX + 40, y: bottom.y))
        path.addLine(to: CGPoint(x: rect.maxX + 40, y: -40))
        path.addLine(to: CGPoint(x: top.x, y: -40))
        path.closeSubpath()
        return path
    }
}

struct Sheet: View {
    let fold: Fold
    let colors: [Color]

    var body: some View {
        ZStack {
            fold.fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(fold.fill(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.28)], startPoint: .leading, endPoint: .trailing)))
                .shadow(color: .black.opacity(0.35), radius: 22, x: -8, y: 6)
            fold.edge.stroke(.white.opacity(0.45), lineWidth: 0.8)
        }
    }
}

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x553B29), Color(hex: 0x76563C), Color(hex: 0x3A2D35), Color(hex: 0x14121A)], startPoint: .top, endPoint: .bottom)
            Sheet(fold: Fold(top: CGPoint(x: -40, y: 90), control1: CGPoint(x: 260, y: 160), control2: CGPoint(x: -90, y: 590), bottom: CGPoint(x: 120, y: 884)),
                  colors: [Color(hex: 0xBE8F5C), Color(hex: 0x86695A), Color(hex: 0x2D2A40)])
            Sheet(fold: Fold(top: CGPoint(x: 60, y: -10), control1: CGPoint(x: 420, y: 310), control2: CGPoint(x: 30, y: 610), bottom: CGPoint(x: 240, y: 884)),
                  colors: [Color(hex: 0xC8A988), Color(hex: 0x977F70), Color(hex: 0x474B66)])
            Sheet(fold: Fold(top: CGPoint(x: 250, y: -10), control1: CGPoint(x: 470, y: 380), control2: CGPoint(x: 160, y: 660), bottom: CGPoint(x: 350, y: 884)),
                  colors: [Color(hex: 0xD5BFA6), Color(hex: 0xA89786), Color(hex: 0x6E748C)])
            Sheet(fold: Fold(top: CGPoint(x: 380, y: -10), control1: CGPoint(x: 330, y: 300), control2: CGPoint(x: 470, y: 560), bottom: CGPoint(x: 420, y: 884)),
                  colors: [Color(hex: 0xE2D3C2), Color(hex: 0xBCAD9F), Color(hex: 0x959AAB)])
        }
        .clipped()
    }
}

struct StatusBar: View {
    var showsTime = true

    var body: some View {
        HStack {
            Text("9:41")
                .font(.system(size: 17, weight: .semibold))
                .opacity(showsTime ? 1 : 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(["cellularbars", "wifi", "battery.100percent"], id: \.self) { Image(systemName: $0) }
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
                VStack(spacing: 0) {
                    StatusBar(showsTime: false)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .padding(.top, 10)
                    Text("Sunday, October 25")
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.top, 12)
                    Text("9:41")
                        .font(.system(size: 108, weight: .bold))
                        .tracking(-1)
                        .padding(.top, -8)
                }
                .shadow(color: .black.opacity(0.3), radius: 12, y: 1)
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

struct HomeScreen<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            StatusBar()
            content.padding(.top, 72)
        }
    }
}

struct Card: View {
    let name: String
    var marks: [Mark] = []

    var body: some View {
        let image = capture("\(name).lock")
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: image.size.width, height: image.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .marked(marks)
    }
}

struct HomeWidget: View {
    let name: String
    var marks: [Mark] = []

    var body: some View {
        let image = capture(name)
        VStack(spacing: 5) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width, height: image.size.height)
                .marked(marks)
            Text("Lykta")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
        }
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

enum BannerPart {
    case sender, body
}

struct Banner: View {
    let example: String
    var time = "now"
    var marks: [BannerPart: Color] = [:]

    var body: some View {
        let request = try! JSONSerialization.jsonObject(with: Data(contentsOf: captures.appending(path: "cards/notifications/\(example).json"))) as! [String: Any]
        let sender = request["sender"] as! [String: Any]
        HStack(spacing: 12) {
            Image(nsImage: capture("\(example).avatar"))
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    AppIcon().frame(width: 18, height: 18).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: marks.count == 2 ? 10 : 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(sender["name"] as! String).font(.system(size: 15, weight: .semibold)).ring(marks[.sender])
                    Spacer()
                    Text(time).font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))
                }
                Text(request["body"] as! String).font(.system(size: 15)).lineLimit(3).ring(marks[.body])
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 370)
        .background(Color(red: 0.07, green: 0.07, blue: 0.1).opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

typealias Phrase = (String, Color?)

struct Headline: View {
    let phrases: [Phrase]
    var size: CGFloat = 88

    var body: some View {
        let text = (phrases + [("”", nil)]).reduce(AttributedString()) { result, phrase in
            var run = AttributedString(phrase.0)
            run.foregroundColor = phrase.1 ?? ink
            return result + run
        }
        ZStack(alignment: .topLeading) {
            Text("“").foregroundStyle(DarkKey.pink).alignmentGuide(.leading) { $0[.trailing] }
            Text(text)
        }
        .font(.system(size: size, weight: .bold).leading(.tight))
        .tracking(-2.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 104)
    }
}

struct Reply: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(ink, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Your agent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.45))
                Text(text)
                    .font(.system(size: 17))
                    .foregroundStyle(ink.opacity(0.78))
                    .fixedSize()
            }
        }
        .magnified(2.7)
        .padding(.leading, 104)
    }
}

struct Paper<Words: View, Screen: View>: View {
    let phoneTop: CGFloat
    @ViewBuilder let words: Words
    @ViewBuilder let screen: Screen

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: paper, startPoint: .top, endPoint: .bottom)
            Phone { screen }
                .frame(width: canvas.width)
                .offset(y: phoneTop)
            words
        }
        .frame(width: canvas.width, height: canvas.height)
        .clipped()
    }
}

struct Exchange: View {
    let phrases: [Phrase]
    let reply: String

    var body: some View {
        VStack(alignment: .leading, spacing: 56) {
            Headline(phrases: phrases)
            Reply(text: reply)
        }
    }
}

func request<Screen: View>(_ phrases: [Phrase], reply: String, phoneTop: CGFloat = 860, @ViewBuilder screen: () -> Screen) -> AnyView {
    AnyView(Paper(phoneTop: phoneTop) {
        Exchange(phrases: phrases, reply: reply).padding(.top, 160)
    } screen: {
        screen()
    })
}

let slides: [(String, AnyView)] = [
    ("1-three", request([("Help me keep\ntrack of ", nil), ("Dad’s train", DarkKey.teal), (",\n", nil), ("the apple pie", DarkKey.amber), (" and\n", nil),
                         ("Mia’s swim heat", DarkKey.pink), (".", nil)], reply: "Done. All three are on\nyour Lock Screen.", phoneTop: 900) {
        LockScreen {
            Card(name: "dads-train").outlined(Key.teal)
            Card(name: "apple-pie").outlined(Key.amber)
            Card(name: "swim-meet").outlined(Key.pink)
        }
    }),
    ("2-launch", request([("Count down to ", nil), ("tonight’s\nlaunch", DarkKey.amber), (", with ", nil), ("the weather\nodds", DarkKey.teal), (", and ", nil),
                          ("draw its path", DarkKey.pink), (".", nil)], reply: "It’s set. It counts\ndown on its own.") {
        LockScreen {
            Card(name: "launch", marks: Marks.launch)
        }
    }),
    ("3-passport", AnyView(Paper(phoneTop: 1240) {
        VStack(alignment: .leading, spacing: 26) {
            Text("“Track my passport renewal.”")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(ink.opacity(0.5))
            Card(name: "passport-before").magnified(1.5)
        }
        .padding(.leading, 104)
        .padding(.top, 140)
        Exchange(phrases: [("Now ", nil), ("show me\nevery step", DarkKey.amber), (".", nil)], reply: "Done. Same passport,\nevery step.")
            .padding(.top, 560)
    } screen: {
        LockScreen {
            Card(name: "passport-steps", marks: Marks.passport)
        }
    })),
    ("4-lake", request([("I want to know\n", nil), ("how warm the lake is", DarkKey.teal), ("\nand ", nil), ("whether to swim", DarkKey.amber), (".", nil)],
                       reply: "Ready. Add the Lykta widget\nand pick Lake.") {
        HomeScreen {
            VStack(spacing: 20) {
                HStack(spacing: 24) {
                    HomeWidget(name: "lake.systemSmall", marks: Marks.lake)
                    HomeWidget(name: "pumpkin-patch.systemSmall")
                }
                HomeWidget(name: "dinners.systemMedium")
            }
        }
    }),
    ("5-sneakers", request([("Tell me when ", nil), ("the trail\nrunners", DarkKey.teal), (" are back in\n", nil), ("size 10", DarkKey.pink), (".", nil)],
                           reply: "I’ll message you the\nmoment they’re back.") {
        LockScreen {
            Banner(example: "sneaker-drop", marks: [.sender: Key.teal, .body: Key.pink])
            Banner(example: "vet", time: "2h ago")
        }
    }),
]

enum Marks {
    static let launch: [Mark] = []
    static let passport: [Mark] = []
    static let lake: [Mark] = []
}

MainActor.assumeIsolated {
    var drawn = Set<Data>()
    for (name, slide) in slides {
        let renderer = ImageRenderer(content: slide.environment(\.colorScheme, .dark))
        guard let rendered = renderer.cgImage,
              let rgba = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let context = CGContext(data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { fatalError("could not render \(name)") }
        let bounds = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
        rgba.clear(bounds)
        rgba.draw(rendered, in: bounds)
        let pixels = UnsafeBufferPointer(start: rgba.data!.assumingMemoryBound(to: UInt8.self), count: rendered.width * rendered.height * 4)
        guard !stride(from: 3, to: pixels.count, by: 4).contains(where: { pixels[$0] != 255 }) else {
            fatalError("\(name) rendered with transparent pixels instead of covering its canvas")
        }
        guard drawn.insert(Data(pixels)).inserted else { fatalError("\(name) rendered the same pixels as an earlier slide") }
        context.draw(rendered, in: bounds)
        let url = output.appending(path: "\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fatalError("could not create \(url.path)")
        }
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
    }
}
