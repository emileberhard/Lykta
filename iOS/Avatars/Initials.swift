import CryptoKit
import UIKit

nonisolated enum Initials {
    static func avatar(of name: String, sender: String) -> Data {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map { $0.uppercased() }.joined()
        let hue = CGFloat(SHA256.hash(data: Data(sender.utf8)).withUnsafeBytes { $0[0] }) / 256
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: hue, saturation: 0.65, brightness: 0.75, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
            let text = NSAttributedString(string: letters, attributes: [
                .font: UIFont.systemFont(ofSize: letters.count > 1 ? 100 : 120, weight: .semibold), .foregroundColor: UIColor.white,
            ])
            let bounds = text.size()
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }
    }
}
