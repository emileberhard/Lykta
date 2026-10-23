import AppKit

let width = 1206.0, height = 2622.0
let slides: [(file: String, title: String, subtitle: String)] = [
    ("1-lock", "Your agents' work,\non the Lock Screen", "Builds, tests and deploys as native Live Activities"),
    ("2-compact", "Progress at a glance\nin the Dynamic Island", "Timers and progress keep running on the phone"),
    ("3-expanded", "Press and hold\nfor the details", "Your agent designs every presentation"),
    ("4-app", "Copy the setup,\nhand it to your agent", "One HTTP request starts an activity"),
]
let raw = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])

for (index, slide) in slides.enumerated() {
    guard let shot = NSImage(contentsOf: raw.appending(path: slide.file + ".png")) else { continue }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 32)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.07, blue: 0.04, alpha: 1),
                        NSColor(srgbRed: 0.30, green: 0.18, blue: 0.06, alpha: 1)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: canvas, angle: 90)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = 4
    let title = NSAttributedString(string: slide.title, attributes: [
        .font: NSFont.systemFont(ofSize: 92, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: paragraph])
    let subtitle = NSAttributedString(string: slide.subtitle, attributes: [
        .font: NSFont.systemFont(ofSize: 46, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 1, green: 0.78, blue: 0.48, alpha: 1), .paragraphStyle: paragraph])
    title.draw(in: NSRect(x: 60, y: height - 330, width: width - 120, height: 240))
    subtitle.draw(in: NSRect(x: 60, y: height - 420, width: width - 120, height: 70))

    let scale = 0.8
    let frame = NSRect(x: (width - width * scale) / 2, y: 0 - 60, width: width * scale, height: height * scale)
    let radius = 62.0 * 3 * scale
    let clip = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(srgbRed: 1, green: 0.6, blue: 0.2, alpha: 0.35)
    shadow.shadowBlurRadius = 60
    shadow.set()
    NSColor.black.setFill()
    clip.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    shot.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.18).setStroke()
    clip.lineWidth = 3
    clip.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: out.appending(path: String(format: "%02d-%@.png", index + 1, slide.file)))
}