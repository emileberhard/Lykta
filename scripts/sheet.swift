import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments.dropFirst()
let output = URL(filePath: arguments.first!)
let rows = arguments.dropFirst().map { row in
    let fields = row.split(separator: "\t").map(String.init)
    let images = fields.dropFirst().map { path in
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil)!, 0, nil)!
    }
    return (label: fields[0], images: images)
}

let gap = 48, label = 72
let width = rows.map { $0.images.reduce(gap) { $0 + $1.width + gap } }.max()!
let height = rows.reduce(gap) { $0 + label + $1.images.map(\.height).max()! + gap }
let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

var top = gap
for row in rows {
    let tallest = row.images.map(\.height).max()!
    let text = NSAttributedString(string: row.label, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("SF Pro Display Bold" as CFString, 44, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ])
    context.textPosition = CGPoint(x: gap, y: height - top - 52)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    var left = gap
    for image in row.images {
        let y = height - top - label - (tallest + image.height) / 2
        context.draw(image, in: CGRect(x: left, y: y, width: image.width, height: image.height))
        left += image.width + gap
    }
    top += label + tallest + gap
}

let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
